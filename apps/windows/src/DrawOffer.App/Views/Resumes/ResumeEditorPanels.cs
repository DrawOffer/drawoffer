using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using S = DrawOffer.App.Views.Resumes.EditorJson;

namespace DrawOffer.App.Views.Resumes;

// 编辑器的面板（Mac `ResumeEditorPanels.swift`），对应 Web 的 `WorkbenchTemplatePanel`、`WorkbenchTypePanel` 与 `WorkbenchSectionOrderControl`。

// MARK: - 切换模板

/// <summary>切换模板（Mac `TemplateSwitchSheet`）：两列缩略图，点击即应用到当前简历；带风格 / 场景筛选与加载、失败、空、无结果状态。</summary>
public sealed class TemplateSwitchSheet : UserControl
{
    readonly Func<ResumeTemplate, Task<string?>> _apply;
    readonly Action _close;
    string _currentKey = "";
    bool _disabled;

    List<ResumeTemplate> _templates = [];
    bool _loading = true, _failed, _scrolled;
    string? _applying, _error;
    readonly List<string> _styles = [], _uses = [];

    List<ResumeTemplate> Filtered => _templates.Where(t =>
        (_styles.Count == 0 || _styles.Intersect(t.StyleCategories).Any()) && (_uses.Count == 0 || _uses.Intersect(t.UseCases).Any())).ToList();

    public static string Key(ResumeTemplate template) => template.Style["template_key"]?.GetValue<string>() ?? template.Key;

    public TemplateSwitchSheet(Func<ResumeTemplate, Task<string?>> apply, Action close)
    {
        _apply = apply;
        _close = close;
        Loaded += async (_, _) => { if (_loading && _templates.Count == 0) await Load(); };
    }

    public void Update(string currentKey, bool disabled)
    {
        _currentKey = currentKey;
        _disabled = disabled;
        Render();
    }

    void Render()
    {
        var grid = new Grid { VerticalAlignment = VerticalAlignment.Stretch };
        for (var i = 0; i < 4; i++) grid.RowDefinitions.Add(new RowDefinition { Height = i == 3 ? Star() : GridLength.Auto });
        grid.Children.Add(WorkbenchPanelHeader.Make("简历模板", "点击模板即可应用到当前简历", "关闭简历模板面板", _close));
        var ready = !_loading && !_failed && _templates.Count > 0;
        if (ready)
        {
            // `.workbench-template-filters`：56 高、左右 24；数量 11.5px fnt，筛选钮 28 高
            var filter = new TemplateFilter(_styles, _uses, Render, height: 28);
            var row = Spread(Sans($"{Filtered.Count} 套模板", 11.5, Fnt), filter, 8);
            row.Padding = new Thickness(24, 0, 24, 0);
            row.Height = 56;
            Grid.SetRow(row, 1);
            grid.Children.Add(row);
        }
        if (_error is { } error) { var text = Sans(error, 12, Red).Wrap().Pad(24, 0, 24, 8); Grid.SetRow(text, 2); grid.Children.Add(text); }
        FrameworkElement body;
        if (_loading) body = VStack(8, new ProgressRing { IsActive = true, Width = 20, Height = 20 }, Sans("正在加载简历模板…", 12, Sub)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        else if (_failed)
            body = State("模板暂时无法加载", "请检查网络后重试，当前简历不会受到影响。", new V3Button("重新加载", () => _ = Load(), V3Button.Kind.Ghost, height: 30, icon: "arrow.clockwise"));
        else if (_templates.Count == 0) body = State("当前没有可用模板", "模板启用后会显示在这里。", null);
        else if (Filtered.Count == 0)
            body = State("没有符合条件的模板", "试试减少一个筛选条件。", new V3Button("清除筛选", () => { _styles.Clear(); _uses.Clear(); Render(); }, V3Button.Kind.Ghost, height: 30));
        else
        {
            // `.workbench-template-grid`：两列，行距 20、列距 12；body 内边距 1/24/24
            var cards = new Grid { Width = 332, ColumnSpacing = 12, RowSpacing = 20, Margin = new Thickness(0, 1, 0, 24), HorizontalAlignment = HorizontalAlignment.Center };
            cards.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            cards.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var list = Filtered;
            FrameworkElement? current = null;
            for (var i = 0; i < list.Count; i++)
            {
                if (i % 2 == 0) cards.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var card = Card(list[i]);
                Grid.SetRow(card, i / 2);
                Grid.SetColumn(card, i % 2);
                cards.Children.Add(card);
                if (Key(list[i]) == _currentKey) current = card;
            }
            var scroll = new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
            // Web 打开时把当前模板滚到可视区中间
            if (current is not null && !_scrolled)
            {
                scroll.Loaded += (_, _) => scroll.DispatcherQueue.TryEnqueue(() =>
                {
                    var top = current.TransformToVisual(cards).TransformPoint(new Point(0, 0)).Y;
                    scroll.ChangeView(null, Math.Max(0, top + current.ActualHeight / 2 - scroll.ViewportHeight / 2), null, true);
                    _scrolled = true;
                });
            }
            body = scroll;
        }
        Grid.SetRow(body, 3);
        grid.Children.Add(body);
        Content = grid;
    }

    /// <summary>`.workbench-template-state`：最少 190 高、居中；标题 13/500 txt，说明 12px fnt，间距 8。</summary>
    static FrameworkElement State(string title, string detail, FrameworkElement? action)
    {
        if (action is not null) action.HorizontalAlignment = HorizontalAlignment.Center;
        var stack = VStack(8, Sans(title, 13, Txt, Medium).Align(HorizontalAlignment.Center), Sans(detail, 12, Fnt).Wrap().Pad(0, 0, 0, 6).Align(HorizontalAlignment.Center), action);
        stack.MinHeight = 190;
        stack.Padding = new Thickness(24, 16, 24, 0);
        stack.VerticalAlignment = VerticalAlignment.Top;
        foreach (var child in stack.Children.OfType<TextBlock>()) child.TextAlignment = TextAlignment.Center;
        return stack;
    }

    /// <summary>
    /// `.workbench-template-card`：纸面 210:297、圆角 6、#d3d3ce 描边（悬停 #b9b9b3，选中蓝色 2 层）；名称 12px（选中 500）、间距 10；
    /// 选中右上 18 黑底白勾；应用中纸面上盖 70% 白与转圈。
    /// </summary>
    FrameworkElement Card(ResumeTemplate template)
    {
        var current = Key(template) == _currentKey;
        var paper = new Grid();
        paper.Children.Add(TemplateThumbnail.Make(template, false));
        paper.Children.Add(new Border { CornerRadius = new CornerRadius(6), BorderBrush = Brush(current ? Blue : Clear), BorderThickness = new Thickness(2), IsHitTestVisible = false });
        if (current)
        {
            var check = new Border
            {
                Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = Brush(Txt), Margin = new Thickness(8),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                Child = Icon("checkmark", 9, V3.White).Also(i => { i.FontWeight = Bold; i.HorizontalAlignment = HorizontalAlignment.Center; i.VerticalAlignment = VerticalAlignment.Center; }),
            };
            AutomationProperties.SetAccessibilityView(check, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            paper.Children.Add(check);
        }
        if (_applying == template.Id)
            paper.Children.Add(new Border { CornerRadius = new CornerRadius(6), Background = Brush(Alpha(V3.White, 0.7)), Child = new ProgressRing { IsActive = true, Width = 16, Height = 16 } });
        var card = VStack(10, paper, Sans(template.Name, 12, Txt, current ? Medium : Regular).Frame(height: 22));
        card.Background = Brush(Clear);
        var label = current ? $"{template.Name}（当前模板）" : $"应用模板：{template.Name}";
        card.OnTap(() => _ = Choose(template), label, () => !_disabled && _applying is null);
        if (current) AutomationProperties.SetItemStatus(card, "已选中");
        card.Opacity = !_disabled && _applying is null || _applying == template.Id ? 1 : 0.6;
        return card;
    }

    async Task Choose(ResumeTemplate template)
    {
        if (Key(template) == _currentKey) return;
        _applying = template.Id; _error = null;
        Render();
        _error = await _apply(template);
        _applying = null;
        Render();
    }

    async Task Load()
    {
        _loading = true; _failed = false;
        Render();
        try { _templates = (await App.Session.Api.ListResumeTemplatesAsync()).Where(x => !ResumeRequest.RetiredTemplateKeys.Contains(x.Key)).ToList(); }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _failed = true;
        }
        finally { _loading = false; Render(); }
    }
}

// MARK: - 版式设置

/// <summary>
/// Web `WorkbenchTypePanel` + `WorkbenchPageBar`（Mac `TypeSettingsPanel`）：页面排列（上下 / 左右 / 智能一页）、页边距（两个步进器 + 88 宽页面预览）、
/// 排版（字体下拉、正文字号、正文行距）。步进器控件 116 宽，28×28 描边按钮，数字 12/500。
/// </summary>
public sealed class TypeSettingsPanel : UserControl
{
    readonly Action<ResumeTypeSettings> _changed;
    readonly Action<string> _arrangementChanged;
    ResumeTypeSettings _settings = new(ResumeTypeSettings.SerifStack, 10, 1.5, 16, 14, false);
    string _arrangement = "vertical";
    bool _disabled;

    public TypeSettingsPanel(Action<ResumeTypeSettings> changed, Action<string> arrangement)
    {
        _changed = changed;
        _arrangementChanged = arrangement;
    }

    public void Update(ResumeTypeSettings settings, string arrangement, bool disabled)
    {
        _settings = settings with { };
        _arrangement = arrangement;
        _disabled = disabled;
        Render();
    }

    void Set(Action<ResumeTypeSettings> change)
    {
        var next = _settings with { };
        change(next);
        _changed(next);
    }

    void Render()
    {
        var s = _settings;
        var options = Columns(8,
            (Star(), Option("上下排列", "rectangle.split.1x2", !s.SmartOnePage && _arrangement == "vertical", () =>
            {
                if (s.SmartOnePage) Set(x => x.SmartOnePage = false);
                _arrangementChanged("vertical");
            })),
            (Star(), Option("左右排列", "rectangle.split.2x1", !s.SmartOnePage && _arrangement == "horizontal", () =>
            {
                if (s.SmartOnePage) Set(x => x.SmartOnePage = false);
                _arrangementChanged("horizontal");
            })),
            (Star(), Option("智能一页", "sparkles", s.SmartOnePage, () => Set(x => x.SmartOnePage = !x.SmartOnePage), toggle: true)));
        var preview = new Border
        {
            Width = 88, MinHeight = 108, CornerRadius = new CornerRadius(8), BorderBrush = Brush(Line), BorderThickness = new Thickness(1),
            Child = VStack(10, Icon("rectangle.split.1x2", 22, Blue), Sans("页面预览", 10, Fnt).Align(HorizontalAlignment.Center)).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        AutomationProperties.SetAccessibilityView(preview, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var margins = Columns(16,
            (Star(), VStack(16,
                Stepper("上下边距", "mm", s.VerticalPageMargin, ResumeTypeSettings.VerticalMarginRange, v => Set(x => x.VerticalPageMargin = v)),
                Stepper("左右边距", "mm", s.PageMargin, ResumeTypeSettings.HorizontalMarginRange, v => Set(x => x.PageMargin = v)))),
            (Auto, preview));
        var typeHead = VStack(5,
            HStack(8, Icon("textformat", 13, Blue), Sans("排版", 13, Txt, Medium)).Frame(height: 22),
            Sans("统一调整简历正文的字体、字号和行距。", 11, Fnt).Frame(height: 22));
        typeHead.Margin = new Thickness(0, 0, 0, 13);
        var fontRow = Spread(Sans("字体", 11, Sub, Medium), FontMenu(), 16).Frame(height: 40).Pad(0, 15, 0, 20);
        var root = VStack(0,
            Section("页面排列", "选择多页简历在编辑区中的浏览方式。"),
            options,
            Sans("排列只影响编辑时的浏览方向。", 11, Fnt).Frame(height: 22).Top(10),
            Divider21(),
            Section("页边距", "分别调整上下和左右留白，单位为毫米。"),
            margins,
            Divider21(),
            typeHead,
            fontRow,
            VStack(16,
                Stepper("正文字号", "pt", s.FontSize, ResumeTypeSettings.FontSizeRange, v => Set(x => x.FontSize = v)),
                Stepper("正文行距", "", s.LineHeight, ResumeTypeSettings.LineHeightRange, v => Set(x => x.LineHeight = v))));
        root.Padding = new Thickness(24, 23, 24, 24);
        root.IsHitTestVisible = !_disabled;
        root.Opacity = _disabled ? 0.6 : 1;
        Content = root;
    }

    string FontLabel => ResumeTypeSettings.Fonts.FirstOrDefault(x => x.Value == _settings.FontFamily).Label ?? ResumeTypeSettings.Fonts[0].Label;

    FrameworkElement FontMenu()
    {
        var chevron = Icon("chevron.down", 9, Sub);
        chevron.FontWeight = Medium;
        chevron.HorizontalAlignment = HorizontalAlignment.Right;
        chevron.VerticalAlignment = VerticalAlignment.Center;
        chevron.Margin = new Thickness(0, 0, 8, 0);
        var label = Sans(FontLabel, 13, Txt).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var box = new Grid { Width = 116, Height = 40, CornerRadius = new CornerRadius(8), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
        box.Children.Add(label);
        box.Children.Add(chevron);
        box.OnTap(() =>
        {
            var menu = new MenuFlyout();
            foreach (var font in ResumeTypeSettings.Fonts)
            {
                var item = new MenuFlyoutItem { Text = font.Label };
                var value = font.Value;
                item.Click += (_, _) => Set(x => x.FontFamily = value);
                menu.Items.Add(item);
            }
            menu.ShowAt(box);
        }, "字体");
        return box;
    }

    static Border Divider21() => new() { Height = 1, Background = Brush(Line), Margin = new Thickness(0, 21, 0, 23) };

    static StackPanel Section(string title, string detail)
    {
        var stack = VStack(5, Sans(title, 13, Txt, Medium).Frame(height: 22), Sans(detail, 11, Fnt).Frame(height: 22));
        stack.Margin = new Thickness(0, 0, 0, 13);
        return stack;
    }

    /// <summary>`.wb3-arrangement-options button`：描边 #ececea、圆角 8、内边距 12/4、12/500；图标 46×44 小框；选中蓝边蓝底蓝字。</summary>
    static FrameworkElement Option(string label, string symbol, bool on, Action action, bool toggle = false)
    {
        var ink = on ? Blue : Sub;
        var glyph = new Border
        {
            Width = 46, Height = 44, CornerRadius = new CornerRadius(6), BorderBrush = Brush(on ? Alpha(Blue, 0.4) : Line), BorderThickness = new Thickness(1),
            Child = Icon(symbol, 18, ink).Align(HorizontalAlignment.Center, VerticalAlignment.Center), HorizontalAlignment = HorizontalAlignment.Center,
        };
        var card = new Border
        {
            Child = VStack(10, glyph, Sans(label, 12, ink, Medium).Frame(height: 19).Align(HorizontalAlignment.Center)),
            Padding = new Thickness(4, 12, 4, 12), Height = 99, CornerRadius = new CornerRadius(8),
            Background = Brush(on ? BlueSoft : V3.White), BorderBrush = Brush(on ? Blue : Line), BorderThickness = new Thickness(1),
        };
        card.OnTap(action, label);
        if (on) AutomationProperties.SetItemStatus(card, toggle ? "已开启" : "已选中");
        return card;
    }

    static FrameworkElement Stepper(string label, string unit, double value, (double Min, double Max, double Step) range, Action<double> set)
    {
        var rounded = Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100;
        var number = Number($"{rounded.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture)}{(unit.Length == 0 ? "" : " " + unit)}", 12, Txt, Medium);
        number.HorizontalAlignment = HorizontalAlignment.Center;
        number.MinWidth = 48;
        number.TextAlignment = TextAlignment.Center;
        AutomationProperties.SetName(number, $"{label}当前值");
        var control = Columns(6,
            (Auto, StepButton("minus", $"减小{label}", value <= range.Min, () => set(ResumeTypeSettings.Step(value, -1, range.Min, range.Max, range.Step)))),
            (Star(), number.Align(HorizontalAlignment.Center, VerticalAlignment.Center)),
            (Auto, StepButton("plus", $"增大{label}", value >= range.Max, () => set(ResumeTypeSettings.Step(value, 1, range.Min, range.Max, range.Step)))));
        control.Width = 116;
        return Spread(Sans(label, 12, Sub), control, 8).Frame(height: 28);
    }

    static Border StepButton(string symbol, string label, bool off, Action action)
    {
        var icon = Icon(symbol, 11, Sub);
        icon.FontWeight = Medium;
        var button = new Border
        {
            Width = 28, Height = 28, CornerRadius = new CornerRadius(7), Background = Brush(V3.White), BorderBrush = Brush(Line), BorderThickness = new Thickness(1),
            Child = icon.Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = off ? 0.4 : 1,
        };
        button.OnTap(action, label, () => !off);
        return button;
    }
}

// MARK: - 板块顺序

/// <summary>调整板块顺序（Mac `SectionOrderSheet`）：拖动排序，个人信息固定在最前；双栏模板中各栏分别排序。</summary>
public sealed class SectionOrderSheet : UserControl
{
    readonly IReadOnlyList<JsonNode?> _sections;
    /// <summary>node_id → "sidebar" / "main"；单栏模板为空。</summary>
    readonly Dictionary<string, string> _columns;
    readonly Action<List<JsonNode?>> _apply;
    readonly Action _close;
    List<JsonNode?> _order;
    readonly Dictionary<string, ObservableCollection<object>> _lists = [];

    public SectionOrderSheet(IReadOnlyList<JsonNode?> sections, Dictionary<string, string> columns, Action<List<JsonNode?>> apply, Action close)
    {
        _sections = sections;
        _columns = columns;
        _apply = apply;
        _close = close;
        _order = sections.ToList();
        Render();
    }

    string Side(JsonNode? section) => _columns.TryGetValue(section.Text("node_id"), out var side) ? side : "main";

    void Render()
    {
        var head = VStack(2,
            Sans("调整板块顺序", 16, Txt, Medium),
            Sans(_columns.Count == 0 ? "拖动排序，个人信息固定在最前" : "拖动排序；双栏模板中各栏分别排序，个人信息固定在最前", 12, Sub).Wrap());
        head.Padding = new Thickness(20);
        var list = new StackPanel { Spacing = 4 };
        list.Children.Add(HStack(8, Icon("lock", 12, Fnt), Sans("个人信息", 13, Fnt)).Pad(12, 6, 12, 6));
        _lists.Clear();
        if (_columns.Count == 0) list.Children.Add(Reorderable("", _order));
        else
            foreach (var side in new[] { "sidebar", "main" })
            {
                var group = _order.Where(x => Side(x) == side).ToList();
                if (group.Count == 0) continue;
                list.Children.Add(Sans(side == "sidebar" ? "侧栏" : "主栏", 11, Fnt, Medium).Pad(12, 8, 12, 2));
                list.Children.Add(Reorderable(side, group));
            }
        var scroll = new ScrollViewer { Content = list, MinHeight = 300 };
        var restore = Sans("恢复默认顺序", 13, Link);
        restore.OnTap(() => { _order = ResumeSectionOrder.RestoreDefault(Collect()); Render(); }, "恢复默认顺序");
        var foot = Spread(restore, HStack(10, new V3Button("取消", _close, V3Button.Kind.Ghost), new V3Button("应用", () => { _apply(Collect()); _close(); }, V3Button.Kind.Dark)), 10);
        foot.Padding = new Thickness(20);
        var grid = new Grid { Width = 440, Height = 520 };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(head);
        Grid.SetRow(scroll, 1);
        grid.Children.Add(scroll);
        Grid.SetRow(foot, 2);
        grid.Children.Add(foot);
        // `.keyboardShortcut(.defaultAction)`：Enter 应用
        grid.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _apply(Collect()); _close(); } };
        Content = V3Dialog.Frame(grid, 440);
    }

    /// <summary>`ForEach(...).onMove`：ListView 自带拖动重排；只在同一栏内移动。</summary>
    ListView Reorderable(string side, List<JsonNode?> group)
    {
        var items = new ObservableCollection<object>(group.Select(Row));
        _lists[side] = items;
        return new ListView { ItemsSource = items, CanDragItems = true, CanReorderItems = true, AllowDrop = true, SelectionMode = ListViewSelectionMode.None };
    }

    /// <summary>把各栏的新顺序写回它们原来占据的位置。</summary>
    List<JsonNode?> Collect()
    {
        if (_columns.Count == 0) return _lists.TryGetValue("", out var only) ? only.Select(x => (JsonNode?)((FrameworkElement)x).Tag).ToList() : _order;
        var result = _order.ToList();
        foreach (var (side, items) in _lists)
        {
            var positions = Enumerable.Range(0, result.Count).Where(i => Side(result[i]) == side).ToList();
            var next = items.Select(x => (JsonNode?)((FrameworkElement)x).Tag).ToList();
            for (var i = 0; i < positions.Count && i < next.Count; i++) result[positions[i]] = next[i];
        }
        return result;
    }

    static FrameworkElement Row(JsonNode? section)
    {
        var kind = ResumeDocument.SectionKinds.FirstOrDefault(x => x.Key == section.Text("semantic_kind")).Label ?? "模块";
        var title = ResumeDocument.Value(section.Get("title"));
        var row = Columns(8, (Auto, Icon("line.3.horizontal", 12, Fnt)), (Star(), Sans(title.Length == 0 ? kind : title, 13, Txt)),
            (Auto, title.Length > 0 && title != kind ? Sans(kind, 11, Fnt) : new Border()));
        row.Tag = section;
        row.Padding = new Thickness(0, 6, 0, 6);
        return row;
    }
}

// MARK: - 大纲

/// <summary>
/// 大纲 V2（Mac `OutlinePanel`，Web `WorkbenchOutlinePanel` + `WorkbenchSectionOrderControl`）：头部、「N 个模块 / 恢复默认顺序」、
/// 按栏分组的两行模块行（拖动手柄、标题、摘要、待完善 / 空标签、悬停 ⋯ 菜单），虚线「添加模块」与底部 / 提示。
/// 个人信息固定在第一行，不能拖动。原生端没有分页信息，不显示 Web 的页面缩略图条。
/// </summary>
public sealed class OutlinePanel : UserControl
{
    readonly Func<JsonNode?, string> _label;
    readonly Action<string> _jump;
    readonly Action<int, int> _move;
    readonly Action<List<JsonNode?>> _reorder;
    readonly Action<int, string> _rename;
    readonly Action<int> _remove;
    readonly Action<(string key, string label)> _add;
    readonly Action _close;

    List<JsonNode?> _sections = [];
    JsonNode? _identity;
    Dictionary<string, string> _columns = [];
    IReadOnlySet<string> _flagged = new HashSet<string>();
    bool _disabled;
    string? _renaming;
    string _renameText = "";
    bool _adding;
    string? _dragging;
    readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

    public OutlinePanel(Func<JsonNode?, string> label, Action<string> jump, Action<int, int> move, Action<List<JsonNode?>> reorder,
        Action<int, string> rename, Action<int> remove, Action<(string key, string label)> add, Action close)
    {
        _label = label; _jump = jump; _move = move; _reorder = reorder; _rename = rename; _remove = remove; _add = add; _close = close;
    }

    public void Update(List<JsonNode?> sections, JsonNode? identity, Dictionary<string, string> columns, IReadOnlySet<string> flagged, bool disabled)
    {
        _sections = sections; _identity = identity; _columns = columns; _flagged = flagged; _disabled = disabled;
        Render();
    }

    void Render()
    {
        var offset = _scroll.VerticalOffset;
        var restore = Sans("恢复默认顺序", 11.5, _disabled ? Fnt2 : Sub, Medium);
        restore.OnTap(() => _reorder(ResumeSectionOrder.RestoreDefault(_sections)), "恢复默认顺序", () => !_disabled);
        var count = Spread(Sans($"{_sections.Count + 1} 个模块", 11.5, Fnt), restore, 8).Frame(height: 14);
        count.Margin = new Thickness(8, 14, 8, 6);
        var groups = VStack(12);
        foreach (var group in Groups())
        {
            var rows = VStack(2);
            if (group.first) rows.Children.Add(IdentityRow());
            foreach (var index in group.indices) rows.Children.Add(SectionRow(index));
            groups.Children.Add(VStack(4,
                group.title.Length == 0 ? null : HStack(6, ColumnGlyph.Make(group.title == "侧栏"), Sans(group.title, 11.5, Sub, Medium)).Pad(8, 4, 8, 2),
                rows));
        }
        var content = VStack(0, count, groups, AddButton().Top(10));
        content.Padding = new Thickness(16, 16, 16, 20);
        _scroll.Content = content;

        var slash = new Border
        {
            Child = Number("/", 11, Txt, Semibold), Padding = new Thickness(5, 1, 5, 1), CornerRadius = new CornerRadius(4),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
        var hint = HStack(6, Sans("也可在正文空行输入", 11, Fnt), slash, Sans("选「标题 2」新建模块", 11, Fnt));
        var footer = new Border { Child = hint, Padding = new Thickness(24, 14, 24, 14), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0) };

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(WorkbenchPanelHeader.Make("大纲", "拖动调整顺序，点击定位到正文", "关闭大纲", _close));
        ResumeEditorView.Detach(_scroll);
        Grid.SetRow(_scroll, 1);
        grid.Children.Add(_scroll);
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);
        Content = grid;
        _scroll.DispatcherQueue.TryEnqueue(() => _scroll.ChangeView(null, offset, null, true));
    }

    List<(string title, List<int> indices, bool first)> Groups()
    {
        var all = Enumerable.Range(0, _sections.Count).ToList();
        if (_columns.Count == 0) return [("", all, true)];
        var side = all.Where(i => _columns.GetValueOrDefault(_sections[i].NodeKey()) == "sidebar").ToList();
        var main = all.Where(i => _columns.GetValueOrDefault(_sections[i].NodeKey()) != "sidebar").ToList();
        return new List<(string, List<int>, bool)> { ("侧栏", side, true), ("主栏", main, false) }.Where(x => x.Item2.Count > 0 || x.Item3).ToList();
    }

    /// <summary>个人信息：锁图标、「固定」，摘要是已填的联系方式。</summary>
    FrameworkElement IdentityRow() => OutlineRow.Make("个人信息", ResumeOutline.IdentitySummary(_identity), _flagged.Contains("identity"), empty: false,
        fixedRow: true, current: false, dragging: false, disabled: _disabled, renaming: null, handle: null, menu: null, open: () => _jump("identity"));

    FrameworkElement SectionRow(int index)
    {
        var section = _sections[index];
        var title = _label(section);
        var key = section.NodeKey();
        var empty = ResumeOutline.IsEmpty(section);
        var handle = Icon("line.3.horizontal", 11, Fnt2).Frame(20, 34);
        var handleHost = new Border { Child = handle.Align(HorizontalAlignment.Center, VerticalAlignment.Center), Width = 20, Height = 34, Background = Brush(Clear) };
        AutomationProperties.SetName(handleHost, $"调整「{title}」顺序，可用上下方向键移动");
        handleHost.IsTabStop = false;
        // `.accessibilityAction(named: "上移/下移")`：键盘焦点在行上时用上下方向键移动
        var menuButton = new Border { Width = 22, Height = 22, Background = Brush(Clear), Child = Icon("ellipsis", 12, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
        menuButton.OnTap(() =>
        {
            var menu = new MenuFlyout();
            var rename = new MenuFlyoutItem { Text = "重命名", Icon = new FontIcon { Glyph = Icons.Glyph("pencil"), FontFamily = IconFamily } };
            rename.Click += (_, _) => { _renameText = title; _renaming = key; Render(); };
            var jump = new MenuFlyoutItem { Text = "定位到正文", Icon = new FontIcon { Glyph = Icons.Glyph("scope"), FontFamily = IconFamily } };
            jump.Click += (_, _) => _jump(key);
            var remove = new MenuFlyoutItem { Text = "删除模块", Foreground = Brush(Red), Icon = new FontIcon { Glyph = Icons.Glyph("trash"), FontFamily = IconFamily, Foreground = Brush(Red) } };
            remove.Click += (_, _) => _remove(index);
            menu.Items.Add(rename);
            menu.Items.Add(jump);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(remove);
            menu.Items.Add(new MenuFlyoutItem { Text = "连同内容一起删除，可 Ctrl+Z 撤销", IsEnabled = false });
            menu.ShowAt(menuButton);
        }, $"「{title}」更多操作");
        var row = OutlineRow.Make(title, ResumeOutline.Summary(section), _flagged.Contains(section.Text("semantic_kind")), empty, fixedRow: false, current: false,
            dragging: _dragging == key, disabled: _disabled, renaming: _renaming == key ? _renameText : null, handle: handleHost, menu: menuButton,
            open: () => _jump(key), commitRename: value =>
            {
                _renaming = null;
                if (value is { } text && text.Trim().Length > 0) _rename(index, text.Trim());
                Render();
            });
        row.KeyDown += (_, e) =>
        {
            if (_disabled) return;
            if (e.Key == Windows.System.VirtualKey.Up && index > 0) { e.Handled = true; _move(index, index - 1); }
            if (e.Key == Windows.System.VirtualKey.Down && index < _sections.Count - 1) { e.Handled = true; _move(index, index + 1); }
        };
        // `.onDrag` / `.onDrop`：拖动手柄到另一行即与它交换位置
        if (!_disabled)
        {
            handleHost.CanDrag = true;
            handleHost.DragStarting += (_, e) => { _dragging = key; e.Data.SetText(key); row.Opacity = 0.35; };
            handleHost.DropCompleted += (_, _) => { _dragging = null; row.Opacity = 1; };
            row.AllowDrop = true;
            row.DragOver += (_, e) => { e.AcceptedOperation = DataPackageOperation.Move; };
            row.Drop += (_, _) =>
            {
                var from = _sections.FindIndex(x => x.NodeKey() == _dragging);
                _dragging = null;
                if (from < 0 || from == index) return;
                _move(from, index);
            };
        }
        return row;
    }

    /// <summary>`.wb3-outline-add`：37 高虚线框、圆角 10、12.5/500；弹层 332 宽，「还可以添加」与未出现的常用模块、自定义模块与说明。</summary>
    FrameworkElement AddButton()
    {
        var enabled = !_disabled && _sections.Count < 100;
        var ink = !enabled ? Fnt2 : _adding ? Txt : Sub;
        var plus = Icon("plus", 11, ink);
        plus.FontWeight = Medium;
        var label = HStack(6, plus, Sans("添加模块", 12.5, ink, Medium));
        label.HorizontalAlignment = HorizontalAlignment.Center;
        var dash = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            RadiusX = 10, RadiusY = 10, Stroke = Brush(_adding ? Fnt : Fnt2), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 2 },
            Fill = Brush(_adding ? Hex(0xFAFAF9) : Clear),
        };
        var button = new Grid { Height = 37, Background = Brush(Clear) };
        button.Children.Add(dash);
        button.Children.Add(label.Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        button.OnTap(() =>
        {
            _adding = true;
            Render();
            Flyout? flyout = null;
            var present = _sections.Select(x => x.Text("semantic_kind")).ToHashSet();
            var options = ResumeOutline.ModuleOptions.Where(x => !present.Contains(x.Kind)).ToList();
            var list = new StackPanel { Width = 332, Padding = new Thickness(6) };
            if (options.Count > 0)
            {
                list.Children.Add(Sans("还可以添加", 11, Fnt).Pad(10, 8, 10, 6));
                foreach (var option in options)
                {
                    var choice = option;
                    list.Children.Add(MenuRow(VStack(1, Sans(option.Title, 12.5, Txt, Medium).Frame(height: 17), Sans(option.Hint, 11, Fnt).Frame(height: 14)),
                        new Thickness(10, 8, 10, 8), option.Title, () => { flyout?.Hide(); _add((choice.Kind, choice.Title)); }));
                }
                list.Children.Add(new Border { Height = 1, Background = Brush(Line), Margin = new Thickness(0, 2, 0, 2) });
            }
            list.Children.Add(MenuRow(HStack(8, Icon("plus", 11, Sub), Sans("自定义模块", 12.5, Sub, Medium)), new Thickness(10, 9, 10, 9), "自定义模块",
                () => { flyout?.Hide(); _add(("custom", "新模块")); }));
            list.Children.Add(Sans("新模块插入到光标所在模块之后，可再拖动调整", 10.5, Fnt).LineHeight(15).Wrap().Pad(10, 6, 10, 6));
            flyout = V3Popover.Show(button, list, FlyoutPlacementMode.Top, 0);
            flyout.Closed += (_, _) => { _adding = false; Render(); };
        }, "添加模块", () => enabled);
        return button;
    }

    /// <summary>Mac `MenuRowStyle`（`.v3-menu-item:hover`）：悬停 #F4F4F2、6 圆角。</summary>
    static Border MenuRow(UIElement content, Thickness padding, string name, Action action)
    {
        var row = new Border { Child = content, Padding = padding, CornerRadius = new CornerRadius(6), Background = Brush(Clear) };
        row.OnHover(h => row.Background = Brush(h ? Field : Clear));
        row.OnTap(action, name);
        return row;
    }
}

/// <summary>一行模块（Mac `OutlineRow`）：最小 52 高、圆角 10、内边距 9/10/9/8、间距 8；标题 13 行高 16，摘要 11 行高 13；悬停 #fafaf9，⋯ 只在悬停时出现并替换标签。</summary>
static class OutlineRow
{
    public static Grid Make(string title, string summary, bool flagged, bool empty, bool fixedRow, bool current, bool dragging, bool disabled, string? renaming,
        FrameworkElement? handle, FrameworkElement? menu, Action open, Action<string?>? commitRename = null)
    {
        var row = new Grid { MinHeight = 52, Padding = new Thickness(8, 9, 10, 9), CornerRadius = new CornerRadius(10), ColumnSpacing = 8, Opacity = dragging ? 0.35 : 1 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var lead = fixedRow ? Icon("lock", 11, Fnt2).Frame(20, 34) : handle ?? new Border { Width = 20 };
        row.Children.Add(lead);

        FrameworkElement titleView;
        TextBox? field = null;
        if (renaming is not null)
        {
            field = new TextBox
            {
                Text = renaming, FontFamily = SansFamily, FontSize = 13, Height = 22, MinHeight = 0, Padding = new Thickness(6, 1, 6, 0), CornerRadius = new CornerRadius(6),
                BorderBrush = Brush(Blue), BorderThickness = new Thickness(1), Background = Brush(V3.White), Margin = new Thickness(-6, -3, 0, -3),
            };
            field.Resources["TextControlBorderBrushFocused"] = Brush(Blue);
            field.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(1);
            var box = field;
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; commitRename?.Invoke(box.Text); }
                if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; commitRename?.Invoke(null); }
            };
            box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
            titleView = box;
        }
        else titleView = Sans(title, 13, empty ? Fnt : Txt, current ? Medium : Regular).Frame(height: 16);
        var texts = VStack(2, titleView, Sans(summary, 11, Fnt).Frame(height: 13));
        texts.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(texts, 1);
        row.Children.Add(texts);

        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(trailing, 2);
        row.Children.Add(trailing);

        var hover = false;
        void Paint()
        {
            trailing.Children.Clear();
            if (!(hover && !fixedRow))
            {
                if (flagged) trailing.Children.Add(Tag("待完善", Hex(0xB8661A), Hex(0xFBF1E6)));
                else if (empty && !fixedRow) trailing.Children.Add(Tag("空", Fnt, Field));
            }
            else if (fixedRow && flagged) trailing.Children.Add(Tag("待完善", Hex(0xB8661A), Hex(0xFBF1E6)));
            if (fixedRow) trailing.Children.Add(Sans("固定", 11, Fnt2));
            if (hover && !fixedRow && !disabled && menu is not null) { ResumeEditorView.Detach(menu); menu.Margin = new Thickness(0, 0, -3, 0); trailing.Children.Add(menu); }
            row.Background = Brush(current ? Field : hover ? Hex(0xFAFAF9) : Clear);
            if (lead is FontIcon lockIcon) lockIcon.Foreground = Brush(Fnt2);
            else if (lead is Border { Child: FontIcon grip }) grip.Foreground = Brush(hover && !fixedRow && !disabled ? Fnt : Fnt2);
        }
        row.OnHover(h => { hover = h; Paint(); });
        row.Tapped += (_, e) => { if (renaming is null && !IsInside(e.OriginalSource, menu)) open(); };
        ToolTipService.SetToolTip(row, $"跳到「{title}」");
        AutomationProperties.SetName(row, title);
        row.IsTabStop = false;
        Paint();
        return row;
    }

    static bool IsInside(object source, FrameworkElement? target)
    {
        for (var node = source as DependencyObject; node is not null; node = VisualTreeHelper.GetParent(node))
            if (ReferenceEquals(node, target)) return true;
        return false;
    }

    static Border Tag(string text, Color fg, Color bg) => new()
    {
        Child = Sans(text, 10.5, fg, Medium), Padding = new Thickness(6, 2, 6, 2), CornerRadius = new CornerRadius(4), Background = Brush(bg),
    };
}

/// <summary>`.workbench-section-order-column`（Mac `ColumnGlyph`）：12×10 小框，左或右 4 宽实心表示侧栏 / 主栏。</summary>
static class ColumnGlyph
{
    public static FrameworkElement Make(bool left)
    {
        var frame = new Grid { Width = 12, Height = 10, CornerRadius = new CornerRadius(2) };
        frame.Children.Add(new Border { Width = 4, Height = 10, Background = Brush(Fnt), HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right });
        frame.Children.Add(new Border { CornerRadius = new CornerRadius(2), BorderBrush = Brush(Fnt), BorderThickness = new Thickness(1.5) });
        AutomationProperties.SetAccessibilityView(frame, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return frame;
    }
}

// MARK: - 简历检查

/// <summary>简历检查（Mac `CompletenessPanel`，Web `ResumeCompletenessPanel`）：分数与等级、示例内容提示、优先完善与已通过。</summary>
public sealed class CompletenessPanel : UserControl
{
    readonly Action _close;
    ResumeCompleteness? _result;
    bool _passedOpen, _opened;
    readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };

    public CompletenessPanel(Action close) => _close = close;

    public void Update(ResumeCompleteness result)
    {
        _result = result;
        // `.onAppear { passedOpen = incompleteCount == 0 }`
        if (!_opened) { _passedOpen = result.Checks.All(x => x.Status == "passed"); _opened = true; }
        Render();
    }

    void Render()
    {
        if (_result is not { } result) return;
        var incomplete = result.Checks.Where(x => x.Status != "passed").ToList();
        var passed = result.Checks.Where(x => x.Status == "passed").ToList();
        // `.wb3-check-content`：内边距 15/24/24
        var content = VStack(0, Summary(result, incomplete.Count));
        if (result.Caps.Count > 0) content.Children.Add(Caps(result).Top(18));
        // `.wb3-check-section`：上 24；头 16 高、下 12；卡片间距 10
        content.Children.Add(Spread(Sans("优先完善", 13, Txt, Medium), Sans($"{incomplete.Count} 项", 12, Fnt), 8).Frame(height: 16).Pad(0, 24, 0, 12));
        if (incomplete.Count == 0)
            content.Children.Add(new Border
            {
                Child = Sans("基础内容已经齐全，可以继续优化表达质量。", 12, Green).Wrap(), Padding = new Thickness(14, 12, 14, 12),
                CornerRadius = new CornerRadius(10), Background = Brush(GreenSoft),
            });
        else content.Children.Add(VStack(10, incomplete.Select(CheckRow).ToArray()));
        // `.wb3-check-passed`：上 16；40 高 #f4f4f2 圆角 10 的展开行，展开后下 10
        var chevron = Icon("chevron.right", 10, Sub);
        chevron.FontWeight = Semibold;
        chevron.Width = 14;
        chevron.RenderTransformOrigin = new Point(0.5, 0.5);
        chevron.RenderTransform = new RotateTransform { Angle = _passedOpen ? 90 : 0 };
        var toggle = new Border
        {
            Child = Columns(8, (Auto, chevron), (Star(), Sans("已通过", 12.5, Txt, Medium)), (Auto, Sans($"{passed.Count} 项", 12, Fnt))),
            Padding = new Thickness(14, 0, 14, 0), Height = 40, CornerRadius = new CornerRadius(10), Background = Brush(Field), Margin = new Thickness(0, 16, 0, 0),
        };
        toggle.OnTap(() => { _passedOpen = !_passedOpen; Render(); }, $"已通过 {passed.Count} 项");
        if (_passedOpen) AutomationProperties.SetItemStatus(toggle, "已展开");
        content.Children.Add(toggle);
        if (_passedOpen) content.Children.Add(VStack(10, passed.Select(CheckRow).ToArray()).Top(10));
        content.Children.Add(Sans("完整度检查基础信息、结构及技能表达的具体程度，不代表岗位匹配度。", 11, Fnt).LineHeight(16).Wrap().Pad(0, 20.5, 0, 2.5));
        content.Padding = new Thickness(24, 15, 24, 24);
        var offset = _scroll.VerticalOffset;
        _scroll.Content = content;

        var grid = new Grid { VerticalAlignment = VerticalAlignment.Stretch };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.Children.Add(WorkbenchPanelHeader.Make("简历检查", "实时规则检查", "关闭简历检查", _close));
        ResumeEditorView.Detach(_scroll);
        Grid.SetRow(_scroll, 1);
        grid.Children.Add(_scroll);
        Content = grid;
        _scroll.DispatcherQueue.TryEnqueue(() => _scroll.ChangeView(null, offset, null, true));
    }

    /// <summary>
    /// `.wb3-check-summary`：大号仪表盘（`gaugeGeometry(false, 18)`），弧心 34/600 分数与 11px「/ 100」，
    /// 两端 10px 的 0 / 100，开口处 24 高等级胶囊；下方 12px 说明，上距 6。
    /// </summary>
    static FrameworkElement Summary(ResumeCompleteness result, int pending)
    {
        var g = WorkbenchGaugeShape.GaugeGeometry(false, 18);
        var angle = 150.0 * Math.PI / 180;
        var endX = g.R * Math.Cos(angle);
        var endY = g.Cy + g.R * Math.Sin(angle);
        var canvas = new Canvas { Width = g.Width, Height = g.Height };
        canvas.Children.Add(WorkbenchGaugeShape.Make(result.Score, extra: 18));
        var score = VStack(3, Number($"{result.Score}", 34, Txt, Semibold).Frame(height: 41).Align(HorizontalAlignment.Center), Number("/ 100", 11, Fnt, Medium).Align(HorizontalAlignment.Center));
        score.Width = g.Width;
        AutomationProperties.SetName(score, $"当前完整度 {result.Score} 分");
        canvas.Children.Add(score.At(0, g.Cy - 42));
        var zero = Number("0", 10, Fnt2, Medium).Frame(height: 12);
        var hundred = Number("100", 10, Fnt2, Medium).Frame(height: 12);
        canvas.Children.Add(zero);
        canvas.Children.Add(hundred);
        Draw.Place(zero, new Point(g.Cx + endX, endY + 16), 0.5, 0.5);
        Draw.Place(hundred, new Point(g.Cx - endX, endY + 16), 0.5, 0.5);
        var level = new Border { Child = Sans(result.Level, 12, Txt, Medium).Align(v: VerticalAlignment.Center), Padding = new Thickness(12, 0, 12, 0), Height = 24, CornerRadius = Capsule(24), Background = Brush(Field) };
        canvas.Children.Add(level);
        Draw.Place(level, new Point(g.Cx, g.Cy + 42), 0.5, 0.5);
        var text = Sans("当前完整度 · " + (pending > 0 ? $"还有 {pending} 项可以完善" : "所有基础检查均已通过"), 12, Sub).Frame(height: 22);
        text.HorizontalAlignment = HorizontalAlignment.Center;
        canvas.HorizontalAlignment = HorizontalAlignment.Center;
        return VStack(6, canvas, text);
    }

    /// <summary>`.wb3-check-caps`：#f1dfc8 描边、圆角 10、橙色浅底、12/14；标题 12.5/500，原因 11.5px 行高 18。</summary>
    static Border Caps(ResumeCompleteness result)
    {
        var icon = Icon("exclamationmark.triangle", 12, Orange);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 1, 0, 0);
        var texts = VStack(4, Sans("检测到示例内容", 12.5, Txt, Medium));
        foreach (var cap in result.Caps) texts.Children.Add(Sans(cap.Reason, 11.5, Sub).LineHeight(18).Wrap());
        var card = new Border
        {
            Child = Columns(8, (Auto, icon), (Star(), texts)), Padding = new Thickness(14, 12, 14, 12), CornerRadius = new CornerRadius(10),
            Background = Brush(OrangeSoft), BorderBrush = Brush(Hex(0xF1DFC8)), BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetName(card, "分数限制说明");
        return card;
    }

    /// <summary>
    /// `.wb3-check-check`：白底、#e4e4e0 描边、圆角 10、内边距 14；左 22 圆形状态标（橙 / 绿 / 红浅底）；
    /// 标题行 22 高（13/500 名称、11px 得分、右侧状态字）；问题 12px 行高 19，建议 11.5px 行高 18。
    /// </summary>
    static UIElement CheckRow(ResumeCompleteness.Check item)
    {
        var tone = item.Status == "passed" ? Green : item.Status == "failed" ? Red : Orange;
        var soft = item.Status == "passed" ? GreenSoft : item.Status == "failed" ? RedSoft : OrangeSoft;
        var glyph = Icon(item.Status == "passed" ? "checkmark" : item.Status == "failed" ? "exclamationmark" : "minus", 9, tone);
        glyph.FontWeight = Bold;
        var mark = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Brush(soft), Child = glyph.Align(HorizontalAlignment.Center, VerticalAlignment.Center), VerticalAlignment = VerticalAlignment.Top };
        AutomationProperties.SetAccessibilityView(mark, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var status = item.Status == "passed" ? "已通过" : item.Status == "partial" ? "需完善" : "待补充";
        var head = Columns(8, (Auto, Sans(item.Label, 13, Txt, Medium)), (Auto, Number($"{item.Earned}/{item.Max} 分", 11, Fnt, Medium)), (Star(), new Border { MinWidth = 4 }), (Auto, Sans(status, 11, tone, Medium)));
        head.Height = 22;
        foreach (var child in head.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        var texts = VStack(4, head,
            item.Issue is { } issue ? Sans(issue, 12, Sub).LineHeight(19).Wrap().Pad(0, 2, 0, 2) : null,
            item.Recommendation is { } advice ? Sans(advice, 11.5, Fnt).LineHeight(18).Wrap().Pad(0, 2, 0, 2) : null);
        var card = new Border
        {
            Child = Columns(10, (Auto, mark), (Star(), texts)), Padding = new Thickness(14), CornerRadius = new CornerRadius(10),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
        AutomationProperties.SetName(card, $"{item.Label} {item.Earned}/{item.Max} 分 {status}");
        return card;
    }
}

// MARK: - 聚焦这段

/// <summary>
/// 聚焦这段（Mac `SectionFocusSheet`，Web `sectionFocus/FocusSheet.tsx` 的主要流程）：可写一句想怎么改，AI 按写作标准逐条给出建议；
/// 每条建议可选一个改写采用（写回对应行，留在编辑器里由自动保存提交）或跳过，结果记在服务端的分析记录里。
/// </summary>
public sealed class SectionFocusSheet : UserControl
{
    readonly string _resumeId;
    readonly SectionFocus.Unit _unit;
    readonly Func<string, string, bool> _adopt;
    readonly Action _close;
    string _intent;
    bool _loading;
    string? _error;
    JsonNode? _result;
    readonly Dictionary<string, string> _handled = [];
    readonly TextBox _intentBox;

    List<JsonNode?> Notes => S.Arr(_result.Get("notes"));
    List<JsonNode?> Items => S.Arr(_result.Get("review").Get("items"));

    public SectionFocusSheet(string resumeId, SectionFocus.Unit unit, string intent, Func<string, string, bool> adopt, Action close)
    {
        _resumeId = resumeId; _unit = unit; _adopt = adopt; _close = close;
        _intent = intent.Length > 300 ? intent[..300] : intent;
        _intentBox = new TextBox { Text = _intent, PlaceholderText = "可选：想怎么改？比如“突出数据结果”“更简洁”", MaxLength = 300, FontFamily = SansFamily, FontSize = 13 };
        _intentBox.TextChanged += (_, _) => _intent = _intentBox.Text;
        Render();
    }

    void Render()
    {
        var close = new V3Button("关闭", _close, V3Button.Kind.Ghost, height: 28, small: true);
        var head = Spread(VStack(2, Serif("聚焦这段", 20), Sans(_unit.Heading.Length == 0 ? $"{_unit.Lines.Count} 行内容" : _unit.Heading, 12, Fnt)), close, 8, VerticalAlignment.Top);
        var body = VStack(12, head);
        if (_result is null)
        {
            body.Children.Add(Sans("AI 会按写作标准逐行检查这段内容，给出可直接采用的改写；不会自动改你的简历。", 12.5, Sub).Wrap());
            ResumeEditorView.Detach(_intentBox);
            body.Children.Add(_intentBox);
            var lines = VStack(4, _unit.Lines.Select(x => (UIElement)Sans("· " + x.Text, 12, Sub).Wrap(2)).ToArray());
            body.Children.Add(new Border { Child = lines, Padding = new Thickness(10), CornerRadius = new CornerRadius(8), Background = Brush(Stage) });
            var analyze = new V3Button(_loading ? "正在分析…" : "开始分析", () => _ = Analyze(), V3Button.Kind.Dark) { Enabled = !_loading };
            body.Children.Add(Spread(_error is { } e1 ? Sans(e1, 12, Red).Wrap() : new Border(), analyze, 8));
        }
        else
        {
            if (_result.Get("too_thin").Bool()) body.Children.Add(Sans("这段内容太少，先补几句做了什么、结果如何，再来分析会更准。", 12.5, Orange).Wrap());
            if (Notes.Count == 0) body.Children.Add(Sans("这段写得不错，没有需要修改的地方。", 13, Sub));
            var cards = VStack(10, Notes.Select(NoteCard).ToArray());
            body.Children.Add(new ScrollViewer { Content = cards, MaxHeight = 460 });
            var buttons = HStack(10, new V3Button("重新分析", () => { _result = null; _handled.Clear(); Render(); }, V3Button.Kind.Ghost), new V3Button("完成", _close, V3Button.Kind.Dark));
            body.Children.Add(Spread(_error is { } e2 ? Sans(e2, 12, Red).Wrap() : new Border(), buttons, 8));
        }
        body.Padding = new Thickness(22);
        body.Width = 600;
        Content = V3Dialog.Frame(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 600);
    }

    UIElement NoteCard(JsonNode? note)
    {
        var id = note.Text("id");
        var variants = S.Arr(note.Get("variants"));
        _handled.TryGetValue(id, out var state);
        var card = VStack(8, Spread(Sans(note.Text("title"), 13, Txt, Semibold),
            state is null ? new Border() : Sans(state == "done" ? "已采用" : "已跳过", 11.5, state == "done" ? Green : Fnt), 8));
        if (note.Text("quote").Length > 0)
        {
            var quote = Sans("原文：" + note.Text("quote"), 12, Fnt).Wrap();
            if (state == "done") quote.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
            card.Children.Add(quote);
        }
        if (note.Text("detail").Length > 0) card.Children.Add(Sans(note.Text("detail"), 12, Sub).Wrap());
        if (note.Get("demo") is JsonObject demo)
        {
            card.Children.Add(Sans("补全示范：" + demo.Text("text"), 12, Blue).Wrap());
            card.Children.Add(Sans("〔〕里是只有你知道的数据，请在编辑器里补上。", 11, Fnt).Wrap());
        }
        if (state is null)
        {
            foreach (var variant in variants)
            {
                var texts = VStack(2);
                if (variant.Text("label").Length > 0) texts.Children.Add(Sans(variant.Text("label"), 11, Fnt));
                var text = Sans(variant.Text("text"), 12.5, Txt).Wrap();
                text.IsTextSelectionEnabled = true;
                texts.Children.Add(text);
                var risky = S.Arr(variant.Get("risky_terms")).Select(x => x.String()).OfType<string>().ToList();
                if (risky.Count > 0) texts.Children.Add(Sans($"「{string.Join("、", risky)}」原句没有，请确认属实", 11, Orange).Wrap());
                var chosen = variant;
                var adopt = new V3Button("采用", () => _ = Decide(note, chosen), V3Button.Kind.Ghost) { Enabled = note.Text("line_id").Length > 0 };
                adopt.VerticalAlignment = VerticalAlignment.Top;
                card.Children.Add(new Border { Child = Columns(8, (Star(), texts), (Auto, adopt)), Padding = new Thickness(8), CornerRadius = new CornerRadius(7), Background = Brush(Field) });
            }
            var skip = Sans("跳过", 12, Link);
            skip.OnTap(() => _ = Decide(note, null), "跳过");
            skip.HorizontalAlignment = HorizontalAlignment.Right;
            card.Children.Add(skip);
        }
        return new Border { Child = card, Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
    }

    async Task Analyze()
    {
        _loading = true; _error = null;
        Render();
        var body = new JsonObject { ["section"] = _unit.Payload, ["reference"] = new JsonObject { ["kind"] = "general" } };
        var text = _intent.Trim();
        if (text.Length > 0) body["intent"] = text;
        try { _result = await App.Session.Api.CareerRequestAsync($"/api/resumes/{_resumeId}/section-review:analyze", "POST", body: body); }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = SectionFocus.ErrorMessage(error);
        }
        finally { _loading = false; Render(); }
    }

    /// <summary>采用：写回这一行并把服务端的建议项标为 done（附改写前后）；跳过：标为 skipped。</summary>
    async Task Decide(JsonNode? note, JsonNode? variant)
    {
        var noteId = note.Text("id");
        var lineId = note.Text("line_id");
        if (variant is not null)
        {
            var before = _unit.Lines.FirstOrDefault(x => x.Id == lineId)?.Text ?? note.Text("quote");
            if (!_adopt(lineId, variant.Text("text"))) { _error = "这一行已经不在简历里，没能采用。"; Render(); return; }
            _handled[noteId] = "done";
            Render();
            await Patch(noteId, new JsonObject { ["status"] = "done", ["edit"] = new JsonObject { ["line_id"] = lineId, ["before"] = before, ["after"] = variant.Text("text") } });
        }
        else
        {
            _handled[noteId] = "skipped";
            Render();
            await Patch(noteId, new JsonObject { ["status"] = "skipped" });
        }
    }

    async Task Patch(string noteId, JsonObject body)
    {
        if (_result.Get("review").Get("id").String() is not { } reviewId || Items.FirstOrDefault(x => x.Text("note_id") == noteId) is not { } item) return;
        try { await App.Session.Api.CareerRequestAsync($"/api/resumes/{_resumeId}/section-reviews/{reviewId}/items/{item.Text("id")}", "PATCH", body: body); }
        catch (Exception error) { _error = SectionFocus.ErrorMessage(error); Render(); }
    }
}
