using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Resumes;

// 编辑器的两个面板：左边整列的模板栏（Figma 07.1）与纸面上沿的排版卡片（Figma 06.2）。

// MARK: - 模板栏

/// <summary>
/// Figma 07.1 模板栏：贴编辑器左边一整列（356 宽、白底、右侧细线）。标题「换模板」14/500 + 一句说明，
/// 下面一行「场景 全部 / 风格 全部」下拉和总数；两列 132 宽缩略图（名称 12，当前那套墨黑框 +「当前」），先显示 20 套、滚到底再加 20 套。
/// 07.2 悬停预览：鼠标在一套上停 150ms 交给编辑器在纸面临时换成这套；移出整列恢复。点一下才换上。
/// </summary>
public sealed class TemplateSwitchSheet : UserControl
{
    public const double Width356 = 356;

    readonly Func<ResumeTemplate, Task<string?>> _apply;
    readonly Action _close;
    readonly Action<ResumeTemplate?> _preview;
    string _currentKey = "";
    bool _disabled;

    List<ResumeTemplate> _templates = [];
    bool _loading = true, _failed, _scrolled;
    string? _applying, _error, _hovered;
    string? _style, _use;
    int _shown = 20;
    readonly Grid _grid = new();
    ScrollViewer? _scroll;

    List<ResumeTemplate> Filtered => _templates.Where(t =>
        (_style is null || t.StyleCategories.Contains(_style)) && (_use is null || t.UseCases.Contains(_use))).ToList();

    public static string Key(ResumeTemplate template) => template.Style["template_key"]?.GetValue<string>() ?? template.Key;

    public TemplateSwitchSheet(Func<ResumeTemplate, Task<string?>> apply, Action close, Action<ResumeTemplate?> preview)
    {
        _apply = apply;
        _close = close;
        _preview = preview;
        Width = Width356;
        Content = new Border
        {
            Child = _grid, Background = Brush(V3.White), BorderBrush = Brush(Alpha(Hex(0x000000), 0.08)), BorderThickness = new Thickness(0, 0, 1, 0),
        };
        AutomationProperties.SetName(this, "换模板");
        // 移出整列才恢复原纸面；在两张卡之间移动不闪回
        PointerExited += (_, _) => { _hovered = null; _preview(null); };
        Loaded += async (_, _) => { if (_loading && _templates.Count == 0) await Load(); };
        Render();
    }

    public void Update(string currentKey, bool disabled)
    {
        if (_currentKey == currentKey && _disabled == disabled) return;
        _currentKey = currentKey;
        _disabled = disabled;
        Render();
    }

    void Render()
    {
        _grid.Children.Clear();
        _grid.RowDefinitions.Clear();
        for (var i = 0; i < 4; i++) _grid.RowDefinitions.Add(new RowDefinition { Height = i == 3 ? Star() : GridLength.Auto });
        var close = HeadIconStyle.Make("xmark", 11, 24, 6, "收起模板栏", _close);
        close.VerticalAlignment = VerticalAlignment.Top;
        close.Margin = new Thickness(0, -3, 0, 0);
        var head = Spread(VStack(9, Sans("换模板", 14, Txt, Medium), Sans("鼠标停在哪套，右边就先看哪套；点一下才换上", 12, Hex(0x8F8F8A)).Wrap()), close, 8, VerticalAlignment.Top);
        head.Padding = new Thickness(36, 28, 30, 0);
        _grid.Children.Add(head);
        var ready = !_loading && !_failed && _templates.Count > 0;
        if (ready)
        {
            var filters = HStack(18, FilterMenu("场景", TemplateFilter.UseOptions, () => _use, v => _use = v), FilterMenu("风格", TemplateFilter.StyleOptions, () => _style, v => _style = v));
            var row = Spread(filters, Sans($"{Filtered.Count} 套", 11.5, Hex(0x96968F)), 8);
            row.Padding = new Thickness(36, 20, 36, 0);
            row.Height = 50;
            Grid.SetRow(row, 1);
            _grid.Children.Add(row);
        }
        if (_error is { } error) { var text = Sans(error, 12, Red).Wrap().Pad(36, 8, 36, 0); Grid.SetRow(text, 2); _grid.Children.Add(text); }
        FrameworkElement body;
        if (_loading) body = VStack(8, new ProgressRing { IsActive = true, Width = 20, Height = 20 }, Sans("正在加载简历模板…", 12, Sub)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        else if (_failed)
            body = State("模板暂时无法加载", "请检查网络后重试，当前简历不会受到影响。", new V3Button("重新加载", () => _ = Load(), V3Button.Kind.Ghost, height: 30, icon: "arrow.clockwise"));
        else if (_templates.Count == 0) body = State("当前没有可用模板", "模板启用后会显示在这里。", null);
        else if (Filtered.Count == 0)
            body = State("没有符合条件的模板", "试试减少一个筛选条件。", new V3Button("清除筛选", () => { _style = null; _use = null; _shown = 20; Render(); }, V3Button.Kind.Ghost, height: 30));
        else body = Grid2();
        Grid.SetRow(body, 3);
        _grid.Children.Add(body);
    }

    /// <summary>两列缩略图（列距 18、行距 18）；底部一行“已显示几套”，滚到底自动再加 20 套。</summary>
    FrameworkElement Grid2()
    {
        var list = Filtered;
        // 打开时把当前模板滚到可视区中间：先把它所在的那一页显示出来
        var currentIndex = list.FindIndex(x => Key(x) == _currentKey);
        if (!_scrolled && currentIndex >= 0) _shown = Math.Max(_shown, currentIndex + 1);
        var visible = list.Take(_shown).ToList();
        var cards = new Grid { ColumnSpacing = 18, RowSpacing = 18, Margin = new Thickness(36, 14, 36, 16), HorizontalAlignment = HorizontalAlignment.Left };
        cards.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(132) });
        cards.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(132) });
        FrameworkElement? current = null;
        for (var i = 0; i < visible.Count; i++)
        {
            if (i % 2 == 0) cards.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var card = Card(visible[i]);
            Grid.SetRow(card, i / 2);
            Grid.SetColumn(card, i % 2);
            cards.Children.Add(card);
            if (i == currentIndex) current = card;
        }
        var footer = Sans(visible.Count < list.Count ? $"已显示 {visible.Count} / {list.Count} 套 · 滚到底自动加载下 20 套" : $"共 {list.Count} 套", 12, Hex(0x8F8F8A));
        footer.HorizontalAlignment = HorizontalAlignment.Center;
        footer.Margin = new Thickness(0, 0, 0, 24);
        var scroll = new ScrollViewer { Content = VStack(0, cards, footer), VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
        var offset = _scroll?.VerticalOffset;
        _scroll = scroll;
        scroll.ViewChanged += (_, _) =>
        {
            if (_shown >= Filtered.Count || scroll.VerticalOffset < scroll.ScrollableHeight - 40) return;
            _shown += 20;
            Render();
        };
        scroll.Loaded += (_, _) => scroll.DispatcherQueue.TryEnqueue(() =>
        {
            if (!_scrolled && current is not null)
            {
                var top = current.TransformToVisual(cards).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
                scroll.ChangeView(null, Math.Max(0, top + current.ActualHeight / 2 - scroll.ViewportHeight / 2), null, true);
            }
            else if (offset is { } y) scroll.ChangeView(null, y, null, true);
            _scrolled = true;
        });
        return scroll;
    }

    /// <summary>07.1 筛选：「场景 全部」「风格 全部」两个无边框下拉，单选；灰字标签 + 墨黑当前值。</summary>
    FrameworkElement FilterMenu(string title, string[] options, Func<string?> get, Action<string?> set)
    {
        var chevron = Icon("chevron.down", 8, Fnt);
        chevron.FontWeight = Semibold;
        var label = HStack(4, Sans(title, 11.5, Hex(0x96968F)), Sans(get() ?? "全部", 11.5, Txt, Medium), chevron.Align(v: VerticalAlignment.Center));
        var host = new BorderControl { Child = label, Background = Brush(Clear), VerticalAlignment = VerticalAlignment.Center };
        void Pick(string? value) { set(value); _shown = 20; _scrolled = true; Render(); }
        host.OnTap(() =>
        {
            var rows = new List<UIElement> { new V3MenuRow("全部", () => Pick(null), isChecked: get() is null), V3MenuRow.Separator() };
            rows.AddRange(options.Select(option => (UIElement)new V3MenuRow(option, () => Pick(option), isChecked: get() == option)));
            V3Popover.Menu(host, 140, [.. rows]);
        }, title);
        return host;
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

    /// <summary>07.1 模板卡：132 宽 A4 缩略图（当前那套 1.5 墨黑框，悬停 #B9B9B2），下方名称 12（当前 500）与灰字「当前」；应用中盖 70% 白与转圈。</summary>
    FrameworkElement Card(ResumeTemplate template)
    {
        var current = Key(template) == _currentKey;
        var paper = new Grid { Width = 132 };
        paper.Children.Add(TemplateThumbnail.Make(template, false));
        var frame = new Border { CornerRadius = new CornerRadius(6), BorderBrush = Brush(current ? Txt : Clear), BorderThickness = new Thickness(current ? 1.5 : 1), IsHitTestVisible = false };
        paper.Children.Add(frame);
        if (_applying == template.Id)
            paper.Children.Add(new Border { CornerRadius = new CornerRadius(6), Background = Brush(Alpha(V3.White, 0.7)), Child = new ProgressRing { IsActive = true, Width = 16, Height = 16 } });
        var name = Sans(template.Name, 12, current ? Txt : Sub, current ? Medium : Regular);
        var caption = HStack(6, name, current ? Sans("当前", 10.5, Hex(0x96968F)) : null);
        caption.Height = 16;
        var card = VStack(8, paper, caption);
        card.Width = 132;
        card.Background = Brush(Clear);
        card.OnHover(inside =>
        {
            if (!current) frame.BorderBrush = Brush(inside ? Hex(0xB9B9B2) : Clear);
            if (!inside) { if (_hovered == template.Id) _hovered = null; return; }
            _hovered = template.Id;
            _ = Later();
            async Task Later()
            {
                await Task.Delay(150);
                if (_hovered != template.Id || _applying is not null || _disabled) return;
                _preview(current ? null : template);
            }
        });
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

// MARK: - 排版卡片

/// <summary>
/// Figma 06.2 排版卡片：点纸面上沿「字体 · 字号 · 行距 · 共 N 页」从规格行下面弹出，320 宽白卡、圆角 8、#E4E4E0 细边。
/// 四组：页面（共 N 页、智能一页开关）、模块顺序（拖动排序，个人信息固定在最前，右键改名 / 删除，恢复默认顺序）、
/// 文字（字体下拉按黑体 / 宋体 / 楷体分组，每个字体名用它自己的字形；字号、行距滑块）、页边距（上下、左右滑块，毫米）。
/// 改动立刻上纸、可 Ctrl+Z 撤销。
/// </summary>
public sealed class TypeSettingsCard : UserControl
{
    public const double CardWidth = 320;

    readonly Action<ResumeTypeSettings> _changed;
    readonly Action<List<string>> _reorder;
    readonly Action<string, string> _rename;
    readonly Action<string> _remove;
    readonly Func<string, string> _label;

    ResumeTypeSettings _settings = new(ResumeTypeSettings.SerifStack, 10, 1.5, 16, 14, false);
    List<JsonNode?> _sections = [];
    Dictionary<string, string> _columns = [];
    int _pages = 1;
    bool _disabled;
    string _orderKey = "";

    readonly TextBlock _pageCount = Sans("", 12, Fnt);
    readonly V3Switch _smart = new(false, "智能一页");
    readonly TextBlock _fontName = Sans("", 13, Txt);
    readonly V3Slider _size, _line, _vertical, _horizontal;
    readonly StackPanel _order = new() { Spacing = 0 };
    readonly StackPanel _body;

    /// <param name="label">模块的显示名（标题为空时用类型名）。</param>
    public TypeSettingsCard(Action<ResumeTypeSettings> changed, Action<List<string>> reorder, Action<string, string> rename, Action<string> remove, Func<string, string> label)
    {
        _changed = changed;
        _reorder = reorder;
        _rename = rename;
        _remove = remove;
        _label = label;
        _size = new V3Slider("字号", ResumeTypeSettings.FontSizeRange, v => $"{Format(v)} pt", v => Set(s => s.FontSize = v));
        _line = new V3Slider("行距", ResumeTypeSettings.LineHeightRange, v => v.ToString("0.00", CultureInfo.InvariantCulture), v => Set(s => s.LineHeight = v));
        _vertical = new V3Slider("上下", ResumeTypeSettings.VerticalMarginRange, v => $"{Format(v)} mm", v => Set(s => s.VerticalPageMargin = v));
        _horizontal = new V3Slider("左右", ResumeTypeSettings.HorizontalMarginRange, v => $"{Format(v)} mm", v => Set(s => s.PageMargin = v));
        _smart.Toggled += on => Set(s => s.SmartOnePage = on);

        var restore = Sans("恢复默认顺序", 12, Link);
        var restoreTap = new BorderControl { Child = restore, Background = Brush(Clear) };
        restoreTap.OnTap(() => _reorder(ResumeSectionOrder.RestoreDefault(_sections).Select(x => x.Text("node_id")).ToList()), "恢复默认顺序", () => !_disabled && _sections.Count > 1);

        var font = new Border
        {
            Child = Columns(8, (Star(), _fontName), (GridLength.Auto, Icon("chevron.down", 9, Sub).Align(v: VerticalAlignment.Center))),
            Width = 160, Height = 30, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(4),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
        _fontName.VerticalAlignment = VerticalAlignment.Center;
        font.OnTap(() => FontMenu(font), "字体", () => !_disabled);

        _body = VStack(0,
            Title("页面", _pageCount),
            Columns(12, (Star(), VStack(2, Sans("智能一页", 13, Txt), Sans("内容略多于一页时，自动收紧字号和间距放进一页", 11.5, Fnt).Wrap())), (GridLength.Auto, _smart.Align(v: VerticalAlignment.Center))).Top(12),
            Rule(),
            Title("模块顺序", restoreTap),
            _order.Top(8),
            Rule(),
            Title("文字", null),
            Spread(Sans("字体", 12.5, Sub), font, 12).Top(12),
            _size.Top(16),
            _line.Top(14),
            Rule(),
            Title("页边距", null),
            _vertical.Top(12),
            _horizontal.Top(14));
        _body.Padding = new Thickness(21, 19, 21, 21);
        var card = new Border
        {
            Child = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled },
            Width = CardWidth, CornerRadius = new CornerRadius(8), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        }.Elevate(16);
        Content = card;
        AutomationProperties.SetName(this, "排版");
    }

    static string Format(double value) => (Math.Round(value * 100) / 100).ToString("0.##", CultureInfo.InvariantCulture);

    static Grid Title(string text, UIElement? trailing) => Spread(Sans(text, 13, Txt, Medium), trailing ?? new Border(), 8);

    static Border Rule() => new() { Height = 1, Background = Brush(Line), Margin = new Thickness(0, 18, 0, 18) };

    void Set(Action<ResumeTypeSettings> change)
    {
        if (_disabled) return;
        var next = _settings with { };
        change(next);
        _settings = next;
        _changed(next);
    }

    /// <summary>编辑器推来最新的版式、模块与页数；拖动滑块时不重建，只同步数值。</summary>
    public void Update(ResumeTypeSettings settings, List<JsonNode?> sections, Dictionary<string, string> columns, int pages, bool disabled)
    {
        _settings = settings;
        _pages = pages;
        _disabled = disabled;
        _pageCount.Text = $"共 {_pages} 页";
        _smart.IsOn = settings.SmartOnePage;
        _smart.Enabled = !disabled;
        _fontName.Text = FontLabel(settings.FontFamily);
        _fontName.FontFamily = new FontFamily(PreviewFont(settings.FontFamily));
        _size.Set(settings.FontSize, !disabled);
        _line.Set(settings.LineHeight, !disabled);
        _vertical.Set(settings.VerticalPageMargin, !disabled);
        _horizontal.Set(settings.PageMargin, !disabled);
        var key = string.Join("|", sections.Select(x => $"{x.Text("node_id")}:{_label(x.Text("node_id"))}:{ResumeOutline.IsEmpty(x)}")) + "#" + string.Join(",", columns.Select(x => x.Key + x.Value)) + disabled;
        _sections = sections;
        _columns = columns;
        if (key != _orderKey) { _orderKey = key; RenderOrder(); }
    }

    static string FontLabel(string family) => ResumeTypeSettings.Fonts.FirstOrDefault(x => x.Value == family).Label ?? ResumeTypeSettings.Fonts[0].Label;

    /// <summary>字体名用它自己的字形显示（Windows 上取能装到的那一个）。</summary>
    static string PreviewFont(string family) => FontLabel(family) switch
    {
        "霞鹜文楷" => "LXGW WenKai,KaiTi",
        "系统黑体" => "Microsoft YaHei UI,Microsoft YaHei",
        _ => "Source Han Serif SC,SimSun",
    };

    /// <summary>06.2b 字体下拉：按 黑体 / 宋体 / 楷体 分组，每项用它自己的字形，当前项打勾。</summary>
    void FontMenu(FrameworkElement anchor)
    {
        var rows = new List<UIElement>();
        foreach (var (group, label) in new[] { ("黑体", "系统黑体"), ("宋体", "思源宋体"), ("楷体", "霞鹜文楷") })
        {
            if (ResumeTypeSettings.Fonts.FirstOrDefault(x => x.Label == label) is not { Value: { } value }) continue;
            if (rows.Count > 0) rows.Add(V3MenuRow.Separator());
            rows.Add(Sans(group, 11, Fnt).Pad(10, 6, 10, 2));
            var row = new V3MenuRow(label, () => Set(s => s.FontFamily = value), isChecked: _settings.FontFamily == value);
            foreach (var text in FindText(row)) text.FontFamily = new FontFamily(PreviewFont(value));
            rows.Add(row);
        }
        V3Popover.Menu(anchor, 180, [.. rows]);
    }

    static IEnumerable<TextBlock> FindText(DependencyObject node)
    {
        if (node is TextBlock text) yield return text;
        if (node is Border { Child: { } child }) foreach (var found in FindText(child)) yield return found;
        if (node is UserControl { Content: { } content }) foreach (var found in FindText(content)) yield return found;
        if (node is Panel panel) foreach (var item in panel.Children) foreach (var found in FindText(item)) yield return found;
    }

    /// <summary>模块顺序：个人信息固定在最前；单栏一个列表，双栏模板每栏一个列表、只在本栏内拖动。行 34 高，六点手柄 #BEBEB8，空模块灰字。</summary>
    void RenderOrder()
    {
        _order.Children.Clear();
        _order.Children.Add(OrderRow("个人信息", empty: false, locked: true));
        if (_columns.Count == 0) _order.Children.Add(Reorderable(_sections));
        else
            foreach (var side in new[] { "sidebar", "main" })
            {
                var group = _sections.Where(x => Side(x) == side).ToList();
                if (group.Count == 0) continue;
                _order.Children.Add(Sans(side == "sidebar" ? "侧栏" : "主栏", 11, Fnt).Pad(0, 8, 0, 2));
                _order.Children.Add(Reorderable(group));
            }
    }

    string Side(JsonNode? section) => _columns.TryGetValue(section.Text("node_id"), out var side) ? side : "main";

    ListView Reorderable(List<JsonNode?> group)
    {
        var items = new ObservableCollection<object>(group.Select(x => (object)SectionRow(x)));
        var list = new ListView
        {
            ItemsSource = items, CanDragItems = !_disabled, CanReorderItems = !_disabled, AllowDrop = !_disabled, SelectionMode = ListViewSelectionMode.None,
            Padding = new Thickness(0), ItemContainerStyle = ItemStyle(),
        };
        ScrollViewer.SetVerticalScrollMode(list, ScrollMode.Disabled);
        list.DragItemsCompleted += (_, _) =>
        {
            // 把这一栏的新顺序写回它们原来占据的位置，交给纸面（可 Ctrl+Z 撤销）
            var next = items.Select(x => (JsonNode?)((FrameworkElement)x).Tag).ToList();
            var result = _sections.ToList();
            var positions = Enumerable.Range(0, result.Count).Where(i => group.Contains(result[i])).ToList();
            for (var i = 0; i < positions.Count && i < next.Count; i++) result[positions[i]] = next[i];
            _reorder(result.Select(x => x.Text("node_id")).ToList());
        };
        return list;
    }

    static Style ItemStyle()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 0d));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        return style;
    }

    FrameworkElement SectionRow(JsonNode? section)
    {
        var id = section.Text("node_id");
        var row = OrderRow(_label(id), ResumeOutline.IsEmpty(section), locked: false);
        row.Tag = section;
        // 右键：改名 / 删除整个模块（立即改在纸上，可 Ctrl+Z 撤销）
        var menu = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = "重命名", IsEnabled = !_disabled };
        rename.Click += (_, _) => Rename(row, id);
        var remove = new MenuFlyoutItem { Text = "删除模块", IsEnabled = !_disabled, Foreground = Brush(Red) };
        remove.Click += (_, _) => _remove(id);
        menu.Items.Add(rename);
        menu.Items.Add(remove);
        row.ContextFlyout = menu;
        return row;
    }

    static Grid OrderRow(string title, bool empty, bool locked)
    {
        var handle = Icon(locked ? "lock" : "line.3.horizontal", 11, Hex(0xBEBEB8)).Align(v: VerticalAlignment.Center);
        var name = Sans(title, 13, empty || locked ? Fnt : Txt).Align(v: VerticalAlignment.Center);
        UIElement trailing = empty ? Sans("空", 11, Fnt2).Align(v: VerticalAlignment.Center) : new Border();
        var row = Columns(10, (GridLength.Auto, handle), (Star(), name), (GridLength.Auto, trailing));
        row.Height = 34;
        row.Padding = new Thickness(8, 0, 8, 0);
        row.CornerRadius = new CornerRadius(4);
        row.Background = Brush(Clear);
        if (!locked) row.OnHover(h => row.Background = Brush(h ? Stage : Clear));
        AutomationProperties.SetName(row, locked ? $"{title}（固定在最前）" : title);
        return row;
    }

    void Rename(Grid row, string id)
    {
        var box = Input("模块名称", _label(id), 30);
        box.Height = 28;
        V3Popover.Show(row, VStack(8, box, new V3Button("改名", () => { var text = box.Text.Trim(); if (text.Length > 0) _rename(id, text); }, V3Button.Kind.Ghost, height: 28)), padding: 10);
        box.Focus(FocusState.Programmatic);
    }
}

// MARK: - 滑块

/// <summary>
/// Figma 06.2 滑块：标题 12.5 灰字 + 右侧数值 12.5 墨黑；轨道 4 高 #DCDCD8，已选段墨黑；
/// 拇指 20 白圆、#E4E4E0 细边、中间 12 墨黑点。拖动或方向键按步长取值。
/// </summary>
public sealed class V3Slider : UserControl
{
    readonly (double Min, double Max, double Step) _range;
    readonly Func<double, string> _format;
    readonly Action<double> _changed;
    readonly TextBlock _value = Sans("", 12.5, Txt);
    readonly Grid _track = new() { Height = 20 };
    readonly Border _fill = new() { Height = 4, CornerRadius = new CornerRadius(2), Background = Brush(Txt), HorizontalAlignment = HorizontalAlignment.Left };
    readonly Border _thumb;
    double _current;
    bool _enabled = true, _dragging;

    public V3Slider(string label, (double Min, double Max, double Step) range, Func<double, string> format, Action<double> changed)
    {
        _range = range;
        _format = format;
        _changed = changed;
        _thumb = new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new Border { Width = 12, Height = 12, CornerRadius = new CornerRadius(6), Background = Brush(Txt), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        _track.Children.Add(new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Brush(Sk2), Margin = new Thickness(10, 0, 10, 0) });
        _track.Children.Add(_fill);
        _track.Children.Add(_thumb);
        _track.Background = Brush(Clear);
        _track.SizeChanged += (_, _) => Layout();
        _track.PointerPressed += (_, e) =>
        {
            if (!_enabled) return;
            _dragging = _track.CapturePointer(e.Pointer);
            Pick(e.GetCurrentPoint(_track).Position.X);
            e.Handled = true;
        };
        _track.PointerMoved += (_, e) => { if (_dragging) Pick(e.GetCurrentPoint(_track).Position.X); };
        _track.PointerReleased += (_, e) => { _dragging = false; _track.ReleasePointerCapture(e.Pointer); };
        _track.PointerCaptureLost += (_, _) => _dragging = false;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        KeyDown += (_, e) =>
        {
            if (!_enabled) return;
            var direction = e.Key switch { VirtualKey.Left or VirtualKey.Down => -1, VirtualKey.Right or VirtualKey.Up => 1, _ => 0 };
            if (direction == 0) return;
            e.Handled = true;
            Commit(ResumeTypeSettings.Step(_current, direction, _range.Min, _range.Max, _range.Step));
        };
        Content = VStack(6, Spread(Sans(label, 12.5, Sub), _value, 8), _track);
        AutomationProperties.SetName(this, label);
    }

    /// <summary>外部同步数值（拖动中不打断）。</summary>
    public void Set(double value, bool enabled)
    {
        _enabled = enabled;
        Opacity = enabled ? 1 : 0.5;
        if (_dragging) return;
        _current = value;
        Layout();
    }

    void Pick(double x)
    {
        var usable = Math.Max(1, _track.ActualWidth - 20);
        var ratio = Math.Clamp((x - 10) / usable, 0, 1);
        var raw = _range.Min + ratio * (_range.Max - _range.Min);
        var snapped = Math.Round(Math.Round(raw / _range.Step) * _range.Step * 100) / 100;
        Commit(Math.Clamp(snapped, _range.Min, _range.Max));
    }

    void Commit(double value)
    {
        if (Math.Abs(value - _current) < 1e-9) return;
        _current = value;
        Layout();
        _changed(value);
    }

    void Layout()
    {
        _value.Text = _format(_current);
        AutomationProperties.SetItemStatus(this, _value.Text);
        var usable = Math.Max(0, _track.ActualWidth - 20);
        var ratio = _range.Max > _range.Min ? Math.Clamp((_current - _range.Min) / (_range.Max - _range.Min), 0, 1) : 0;
        _thumb.Margin = new Thickness(ratio * usable, 0, 0, 0);
        _fill.Margin = new Thickness(10, 0, 0, 0);
        _fill.Width = ratio * usable;
    }
}
