using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;
using G = DrawOffer.Core.Models.ResumeGuideModel;
using S = DrawOffer.App.Views.Resumes.GuideJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 新建简历的引导（Mac `Features/ResumeGuidePanel.swift`，Web `guide/ResumeGuidePanel.tsx`）：纸面在左，引导在右。每一步一行小字进度、一个大标题、
/// 一句说明、细线列表和唯一的黑色主按钮。表单直写的步骤（求职意向、基本信息、教育、证书与获奖）走 `guide/writes`；
/// 技能、经历、个人简介由 AI 按写作法则写好直接上纸；资料一步把文件交给引导对话读一遍，只用来预填后面的表单。
/// 步骤由服务端记录（`PATCH /api/resumes/{id}/guide`，版本冲突时重新读取）。
/// 界面状态放在字段里，变化后 <see cref="Render"/> 整体重建，并恢复输入框的焦点与光标。
/// 本文件是骨架与通用部件；各步内容见 `.Body.cs`，请求与写入见 `.Actions.cs`，资料 / 技能 / 城市子视图见 `.Steps.cs`。
/// </summary>
public sealed partial class ResumeGuidePanel : UserControl
{
    readonly string _resumeId;
    // Swift `@Binding var guide`：值 + 回写
    JsonNode _guide;
    readonly Action<JsonNode> _setGuide;
    /// <summary>纸面当前正文（含未保存的修改）与这份简历使用的模板 id。</summary>
    JsonNode _data;
    readonly string? _templateId;
    /// <summary>写入前先保存编辑器里的修改；保存失败时返回 false，不写。</summary>
    readonly Func<Task<bool>> _saveFirst;
    /// <summary>服务端写入后返回的最新简历，由编辑器载入；`undo` 收到写之前的正文，撤销时放回。</summary>
    readonly Action<JsonNode> _applied, _undo;
    readonly Action _exportPdf, _close;

    sealed record Failure(string Kind, Action Retry);
    sealed record LastWrite(string Step, JsonNode Before, string Label);

    List<JsonNode?> _messages = [];
    List<JsonNode?> _proposals = [];
    bool _running;
    string _streamText = "";
    Failure? _failure;
    bool _busy;
    string? _notice;
    string _answer = "";
    bool _welcome;
    LastWrite? _lastWrite;
    JsonNode? _profile, _career;
    bool _careerReady;
    JsonNode? _templateSample;
    readonly HashSet<string> _confirmed = [];
    /// <summary>一次点击里会连着推进几次（写入后再“下一步”），版本号要立即可见，不能等界面刷新（Web `guideRef`，Swift `Latest`）。</summary>
    JsonNode? _ref;

    G.JobIntent? _jobIntent;
    G.BasicInfo? _basicInfo;
    G.EducationForm? _education;
    List<(string Name, string Level)>? _skills;
    G.ExperienceForm? _experience;
    string _phase = "form";
    string _skillPhase = "form";
    List<JsonNode?> _skillLines = [];
    string _wrapPhase = "main";
    string _profileText = "";
    G.HonorsForm? _honors;
    List<JsonNode?> _bullets = [];
    readonly HashSet<string> _unused = [];
    G.ExperienceItem? _opened;

    // 界面：每次 Render 重建；输入框按读屏名登记，用来在重建后恢复焦点与光标
    readonly Grid _host = new();
    ScrollViewer? _scroller;
    readonly Dictionary<string, TextBox> _boxes = [];
    // 输入时不整体重建，只重算依赖文字的按钮可用状态
    readonly List<Action> _refresh = [];
    string _lastStep;
    bool _started;

    public ResumeGuidePanel(string resumeId, JsonNode guide, Action<JsonNode> setGuide, JsonNode data, string? templateId, Func<Task<bool>> saveFirst,
        Action<JsonNode> applied, Action<JsonNode> undo, Action exportPdf, Action close)
    {
        _resumeId = resumeId;
        _guide = guide;
        _setGuide = setGuide;
        _data = data;
        _templateId = templateId;
        _saveFirst = saveFirst;
        _applied = applied;
        _undo = undo;
        _exportPdf = exportPdf;
        _close = close;
        _lastStep = Step;
        // Web `.wb3-guide`：440 宽、没有卡片框和白底，内边距 4/2/32；关闭靠工具卡片「引导」或 Esc（由编辑器处理）。
        Width = 440;
        VerticalAlignment = VerticalAlignment.Stretch;
        HorizontalAlignment = HorizontalAlignment.Left;
        Content = _host;
        AutomationProperties.SetName(this, "引导创建简历");
        Loaded += (_, _) => { if (_started) return; _started = true; _ = StartAsync(); };
        Render();
    }

    /// <summary>编辑器推来新的引导状态或纸面正文（Swift 绑定与 `data` 参数变化）。</summary>
    public void Update(JsonNode guide, JsonNode data)
    {
        // 编辑器每次重绘都会推送；内容没变时不重建，避免打断面板里的输入
        if (JsonNode.DeepEquals(guide, _guide) && JsonNode.DeepEquals(data, _data)) return;
        _guide = guide;
        _data = data;
        StepMaybeChanged();
        Render();
    }

    // MARK: 派生状态

    string Step => _guide.Text("current_step").Length == 0 ? "materials" : _guide.Text("current_step");
    string SessionId => _guide.Text("session_id");
    HashSet<string> Samples => G.SampleIDs(_guide);
    JsonNode? Materials => G.MaterialsDocument(_proposals);
    List<G.ExperienceItem> ExperienceItems => G.ExperienceList(_data, Materials, Samples, _unused);
    bool ListMode => ExperienceItems.Count >= 2;
    static int StepIndex(string step) => G.Steps.ToList().IndexOf(step);

    /// <summary>这一步 AI 写好、还没确认的草稿：最近一次（技能、经历自动上纸；资料只用来数“读到了几项”）。</summary>
    JsonNode? Draft
    {
        get
        {
            var cutoff = Cutoff;
            var recentRuns = _messages.Where(m => (m.Get("sequence_no").Number() ?? 0) > cutoff).Select(m => m.Text("run_id")).Where(x => x.Length > 0).ToHashSet();
            return S.MaxBy(_proposals.Where(p => p.Text("proposal_mode") == "guided_fill" && p.Get("preview").Text("step") == Step && p.Text("status") == "pending"
                    && recentRuns.Contains(p.Text("run_id"))).OfType<JsonNode>(),
                (a, b) => S.Cmp(a.Text("created_at"), b.Text("created_at")) < 0);
        }
    }

    double Cutoff
    {
        get
        {
            var applied = _proposals.Where(p => p.Text("proposal_mode") == "guided_fill" && p.Get("preview").Text("step") == Step && p.Text("status") == "applied")
                .Select(p => p.Text("run_id")).ToHashSet();
            var numbers = _messages.Where(m => applied.Contains(m.Text("run_id"))).Select(m => m.Get("sequence_no").Number() ?? 0).ToList();
            return numbers.Count == 0 ? 0 : numbers.Max();
        }
    }

    Action? Back
    {
        get
        {
            var index = StepIndex(Step);
            if (index <= 0 || _guide.Text("status") != "active") return null;
            var previous = G.Steps[index - 1];
            return G.StepState(_guide, previous) == "done" ? () => _ = Try(() => ChangeAsync("goto_step", previous)) : null;
        }
    }

    // MARK: 骨架

    void Render()
    {
        var focusedKey = _boxes.FirstOrDefault(p => p.Value.FocusState != FocusState.Unfocused).Key;
        var selection = focusedKey is not null ? _boxes[focusedKey].SelectionStart : 0;
        var offset = _scroller?.VerticalOffset ?? 0;
        _boxes.Clear();
        _refresh.Clear();
        _materialsUsed = _skillLevelsUsed = _citiesUsed = false;

        var column = new StackPanel { Padding = new Thickness(2, 4, 2, 32), HorizontalAlignment = HorizontalAlignment.Stretch };
        column.Children.Add(Body());
        if (_notice is { } notice) column.Children.Add(Sans(notice, 13, Red).Wrap().Top(20));
        if (_notice is null && _lastWrite is { } last && !_busy && !_running)
        {
            var undo = Tap(Sans("撤销", 13, Blue), () => _ = UndoLastAsync(), "撤销");
            column.Children.Add(HStack(8, Icon("checkmark", 11, Fnt), Sans($"{last.Label}已写进左边", 13, Fnt), undo).Top(20));
        }
        // 子视图的状态随视图存在：这次没显示的，下次出现时从头开始（SwiftUI @State 的生命周期）
        if (!_materialsUsed) _materialsView = null;
        if (!_skillLevelsUsed) _skillLevelsView = null;
        if (!_citiesUsed) _cityInput = "";

        var scroller = new ScrollViewer
        {
            Content = column, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        };
        _scroller = scroller;
        _host.Children.Clear();
        _host.Children.Add(scroller);
        scroller.Loaded += (_, _) => scroller.ChangeView(null, offset, null, true);
        if (focusedKey is not null && _boxes.TryGetValue(focusedKey, out var box))
            box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectionStart = Math.Min(selection, box.Text.Length); };
        RunRefresh();
    }

    void RunRefresh() { foreach (var refresh in _refresh) refresh(); }

    /// <summary>每一步的骨架：返回链接与进度、7 段进度条、28px 标题（可带转圈）、15px 说明，再接各步内容。</summary>
    FrameworkElement StepView(string step, string title, string? note = null, bool thinking = false, Action? back = null, string backLabel = "上一步",
        params UIElement?[] content)
    {
        var index = Math.Max(0, StepIndex(step)) + 1;
        var stack = new StackPanel { Padding = new Thickness(0, 72, 0, 0) };
        UIElement left = back is not null ? Tap(Sans($"‹ {backLabel}", 13, Fnt), back, $"‹ {backLabel}") : new Border { Width = 1 };
        var head = Spread(left, Sans($"{(G.Labels.TryGetValue(step, out var label) ? label : "")} · {index} / {G.Steps.Count}", 13, Fnt));
        head.MinHeight = 20;
        stack.Children.Add(head);
        var bars = new Grid { ColumnSpacing = 4, Margin = new Thickness(0, 12, 0, 0) };
        for (var position = 0; position < G.Steps.Count; position++)
        {
            bars.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var bar = Fill(position < index ? Txt : Hl, 1.5, height: 3);
            Grid.SetColumn(bar, position);
            bars.Children.Add(bar);
        }
        AutomationProperties.SetAccessibilityView(bars, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        stack.Children.Add(bars);
        var heading = Sans(title, 28, Txt, Bold).LineHeight(38).Wrap();
        heading.CharacterSpacing = -10; // tracking -0.28pt ÷ 28px × 1000
        var titleRow = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 52, 0, 0) };
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        titleRow.Children.Add(heading);
        if (thinking)
        {
            // 与标题首行基线对齐：38 行高里 16 的转圈居中
            var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 11, 0, 0) };
            Grid.SetColumn(ring, 1);
            titleRow.Children.Add(ring);
        }
        stack.Children.Add(titleRow);
        if (note is not null) stack.Children.Add(Sans(note, 15, Sub).LineHeight(24).Wrap().Top(8));
        foreach (var child in content) if (child is not null) stack.Children.Add(child);
        return stack;
    }

    /// <summary>底部操作行：左边文字链接，右边唯一的黑色主按钮；`disabled` 随输入重算。</summary>
    FrameworkElement Actions(UIElement? left = null, string? primary = null, Func<bool>? disabled = null, Action? onPrimary = null)
    {
        UIElement right = new Border();
        if (primary is not null && onPrimary is not null)
        {
            var button = new GuidePrimaryButton(primary, onPrimary);
            if (disabled is not null) _refresh.Add(() => button.Enabled = !disabled());
            right = button;
        }
        var row = Spread(left ?? new Border(), right);
        row.MinHeight = 44;
        row.Margin = new Thickness(0, 40, 0, 0);
        return row;
    }

    FrameworkElement TextLink(string title, Action action, bool disabled = false)
    {
        var link = Tap(Sans(title, 15, Sub), action, title, () => !disabled);
        link.Opacity = disabled ? 0.38 : 1;
        return link;
    }

    /// <summary>表单行：92 宽标签、内容、可选提示，最矮 50，下面一条细线。</summary>
    FrameworkElement Row(string label, UIElement content, string? hint = null)
    {
        var grid = Columns(12, (Px(92), Sans(label, 15, Txt)), (Star(), content), (Auto, hint is null ? new Border() : Sans(hint, 13, Fnt)));
        grid.MinHeight = 50;
        foreach (var child in grid.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        return VStack(0, grid, Divider(Cl));
    }

    /// <summary>无边框单行输入（`TextField.plain`）；`limit` 对应 Swift 的 prefix(limit)。</summary>
    TextBox Field(string placeholder, string value, int limit, Action<string> set, string? label = null, double? width = null)
    {
        var box = PlainBox(placeholder, value, label ?? placeholder);
        box.MaxLength = limit;
        if (width is { } w) box.Width = w;
        box.TextChanged += (_, _) => { set(box.Text); RunRefresh(); };
        return box;
    }

    /// <summary>多行输入（`TextField(axis: .vertical)`，lineLimit 3...10）：15px、上下 14。</summary>
    FrameworkElement Area(string placeholder, string value, int limit, Action<string> set, string label)
    {
        var box = PlainBox(placeholder, value, label);
        box.MaxLength = limit;
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.Wrap;
        box.MinHeight = 3 * 20;
        box.MaxHeight = 10 * 20;
        box.Margin = new Thickness(0, 14, 0, 14);
        box.TextChanged += (_, _) => { set(box.Text); RunRefresh(); };
        return VStack(0, box, Divider(Cl));
    }

    TextBox PlainBox(string placeholder, string value, string label)
    {
        var box = new TextBox
        {
            Text = value, PlaceholderText = placeholder, FontFamily = SansFamily, FontSize = 15, Foreground = Brush(Txt),
            PlaceholderForeground = Brush(Fnt2), Background = Brush(Clear), BorderThickness = new Thickness(0), Padding = new Thickness(0),
            MinHeight = 0, IsSpellCheckEnabled = false, VerticalAlignment = VerticalAlignment.Center,
        };
        // TextBox 默认模板在悬停 / 聚焦时换底色与下划线，统一改成透明
        foreach (var key in new[] { "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" })
            box.Resources[key] = Brush(Clear);
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Hidden);
        AutomationProperties.SetName(box, label);
        _boxes[label] = box;
        return box;
    }

    /// <summary>单选文字组：选中项 15/600 墨黑，其余 #C4C4BE。</summary>
    FrameworkElement Choice(string label, string value, IEnumerable<(string Key, string Title)> options, Action<string> set)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18 };
        foreach (var option in options)
        {
            var selected = value == option.Key;
            var item = Tap(Sans(option.Title, 15, selected ? Txt : Fnt2, selected ? Semibold : Regular), () => set(option.Key), option.Title);
            if (selected) AutomationProperties.SetItemStatus(item, "已选中");
            row.Children.Add(item);
        }
        AutomationProperties.SetName(row, label);
        return row;
    }

    static FrameworkElement Group(string text) => Sans(text, 12, Fnt).Pad(0, 28, 0, 8);

    /// <summary>下划线输入：文字 + 发送键（说怎么改、添加技能）；回车发送，⇧回车换行，输入法组字时回车不发送。</summary>
    FrameworkElement Underline(string placeholder, Func<string> get, Action<string> set, bool disabled, Action<string> send)
    {
        var box = PlainBox(placeholder, get(), placeholder);
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.Wrap;
        box.MaxHeight = 6 * 20;
        box.IsEnabled = !disabled;
        box.VerticalAlignment = VerticalAlignment.Bottom;
        bool Ready() => S.Trimmed(get()).Length > 0 && !disabled;
        void Submit()
        {
            if (!Ready()) return;
            var text = S.Trimmed(get());
            set("");
            send(text);
            Render();
        }
        var circle = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Child = Icon("arrow.up", 12, V3.White).Also(i => i.FontWeight = Semibold) };
        var button = Tap(circle, Submit, "发送", Ready);
        button.VerticalAlignment = VerticalAlignment.Bottom;
        void Paint() => circle.Background = Brush(Ready() ? Txt : Sk2);
        _refresh.Add(Paint);
        var composing = false;
        box.TextCompositionStarted += (_, _) => composing = true;
        box.TextCompositionEnded += (_, _) => composing = false;
        box.TextChanged += (_, _) => { set(box.Text); Paint(); };
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter || composing) return;
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (shift) return;
            e.Handled = true;
            Submit();
        };
        var row = Columns(8, (Star(), box), (Auto, button));
        row.Margin = new Thickness(0, 10, 0, 10);
        return VStack(0, row, Divider(Cl)).Top(24);
    }

    FrameworkElement Meta(string text, string link, Action action) =>
        HStack(12, Sans(text, 13, Fnt), Tap(Sans(link, 13, Blue), action, link)).Top(16);

    /// <summary>整行可点的链接行：15/500 标题、13px 右侧说明，最矮 50，下面细线。</summary>
    FrameworkElement LinkRow(string title, string trailing, Action action, bool disabled = false)
    {
        var grid = Spread(Sans(title, 15, Txt, Medium), Sans(trailing, 13, Fnt));
        grid.MinHeight = 50;
        var row = Tap(VStack(0, grid, Divider(Cl)), action, title, () => !disabled);
        row.Opacity = disabled ? 0.38 : 1;
        return row;
    }

    /// <summary>`.buttonStyle(.plain)`：透明底的可点区域（整块可点，Enter / Space 触发）。</summary>
    static BorderControl Tap(UIElement child, Action action, string? name = null, Func<bool>? enabled = null) =>
        new BorderControl { Child = child, Background = Brush(Clear) }.OnTap(action, name, enabled);
}

/// <summary>`.wb3-guide-primary`（Swift `GuidePrimaryStyle`）：44 高胶囊、内边距 22、15/500 白字墨黑底，最宽 280；按下 85% 不透明，禁用时 #dcdcd8。</summary>
sealed class GuidePrimaryButton : BorderControl
{
    readonly Action _action;
    bool _pressed, _enabled = true;

    public GuidePrimaryButton(string title, Action action)
    {
        _action = action;
        var label = Sans(title, 15, V3.White, Medium);
        label.MaxLines = 1;
        label.VerticalAlignment = VerticalAlignment.Center;
        Child = label;
        Height = 44;
        MaxWidth = 280;
        Padding = new Thickness(22, 0, 22, 0);
        CornerRadius = Capsule(44);
        HorizontalAlignment = HorizontalAlignment.Right;
        AutomationProperties.SetName(this, title);
        PointerPressed += (_, e) => { if (_enabled) { _pressed = true; Paint(); e.Handled = true; } };
        PointerReleased += (_, e) => { if (_pressed && _enabled) { _pressed = false; Paint(); e.Handled = true; _action(); } };
        PointerExited += (_, _) => { _pressed = false; Paint(); };
        PointerCanceled += (_, _) => { _pressed = false; Paint(); };
        IsTabStop = true;
        KeyDown += (_, e) => { if (_enabled && e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; _action(); } };
        Paint();
    }

    public bool Enabled { get => _enabled; set { _enabled = value; Paint(); } }

    void Paint()
    {
        Background = Brush(_enabled ? Alpha(Txt, _pressed ? 0.85 : 1) : Hex(0xDCDCD8));
        ProtectedCursor = InputSystemCursor.Create(_enabled ? InputSystemCursorShape.Hand : InputSystemCursorShape.Arrow);
    }
}
