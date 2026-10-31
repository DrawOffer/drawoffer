using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

/// <summary>
/// 多项修改建议卡（Mac `SuggestionCard`，Web `SuggestionCard.tsx`）：同一轮提问的建议合在一起，标签切换、‹ › 翻看，
/// 采用此项后自动跳到下一项待确认；“全部采用”逐项处理并显示进度；全部处理完收起成一行摘要，可展开回看。
/// </summary>
public sealed class SuggestionCard : UserControl
{
    public sealed record Options(
        IReadOnlyList<JsonNode> Proposals, bool Historical, string ResumeLabel, string? Busy, bool Running,
        (string key, int completed, int total)? Progress, bool Locked,
        Func<JsonNode, Task<bool>> Apply, Func<JsonNode, Task<bool>> Reject, Action ApplyAll,
        Action<JsonNode> ContinueEditing, Action<JsonNode> Preview);

    // 卡片在父视图每次重画时重建，选中项与展开状态按建议组保存
    static readonly Dictionary<string, (string? selected, bool? expanded)> Memory = [];

    readonly Options _o;
    string Key => string.Join(",", _o.Proposals.Select(p => p.Text("id")));
    string? SelectedId { get => Memory.GetValueOrDefault(Key).selected; set => Memory[Key] = (value, Memory.GetValueOrDefault(Key).expanded); }
    bool? Expanded { get => Memory.GetValueOrDefault(Key).expanded; set => Memory[Key] = (Memory.GetValueOrDefault(Key).selected, value); }

    List<JsonNode> Pending => _o.Proposals.Where(p => p.Text("status") == "pending").ToList();

    public SuggestionCard(Options options)
    {
        _o = options;
        Render();
    }

    void Render()
    {
        var pending = Pending;
        var allDone = pending.Count == 0;
        var selected = _o.Proposals.FirstOrDefault(p => p.Text("id") == SelectedId) ?? pending.FirstOrDefault() ?? _o.Proposals.FirstOrDefault();
        if (selected is null) { Content = null; return; }
        var index = Math.Max(0, _o.Proposals.ToList().FindIndex(p => p.Text("id") == selected.Text("id")));
        var applied = _o.Proposals.Count(p => p.Text("status") == "applied");
        var rejected = _o.Proposals.Count(p => p.Text("status") == "rejected");
        var progressText = applied + rejected == 0 ? $"{pending.Count} 项待确认"
            : string.Join(" · ", new[] { applied > 0 ? $"已采用 {applied}" : "", rejected > 0 ? $"已忽略 {rejected}" : "", pending.Count > 0 ? $"待确认 {pending.Count}" : "" }.Where(x => x.Length > 0));
        var isExpanded = Expanded ?? !allDone;
        if (!isExpanded && allDone && _o.Progress is null)
        {
            var check = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Brush(Green), Child = Icon("checkmark", 11, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
            var texts = new StackPanel { Spacing = 2 };
            texts.Children.Add(Sans($"{(_o.Historical ? "历史修改建议 · " : "")}已处理 {_o.Proposals.Count} 处修改建议", 13, Txt, Medium));
            texts.Children.Add(Sans(progressText, 11.5, Fnt));
            var detail = Sans("查看详情", 12, Link).OnTap(() => { Expanded = true; Render(); }, "查看详情");
            Content = Card(Columns(10, (GridLength.Auto, check.Align(v: VerticalAlignment.Center)), (Star(), texts), (GridLength.Auto, detail.Align(v: VerticalAlignment.Center))), 14, new Thickness(14));
            return;
        }
        Content = CardView(selected, index, progressText);
    }

    static string Short(JsonNode proposal, int index)
    {
        var text = proposal.Text("summary").Trim();
        if (text.Length == 0) return $"第 {index + 1} 项";
        return text.Length > 14 ? text[..14] + "…" : text;
    }

    static string? Status(JsonNode proposal) => proposal.Text("status") switch
    {
        "pending" => null,
        "applied" => "已应用",
        "rejected" => "已忽略",
        _ => proposal.Text("superseded_by").Length == 0 ? "无法应用" : "已被替代",
    };

    static List<(string before, string after)> Changes(JsonNode proposal)
    {
        var preview = proposal.Get("preview").Items("changes");
        if (preview.Count > 0) return preview.Select(c => (c.Text("before"), c.Text("after"))).ToList();
        var operations = proposal.Items("operations");
        if (operations.Count > 0)
            return operations.Select(o => (o.Get("target").Text("selected_text").NonEmpty() ?? "当前定位内容", o.Text("op") == "delete_target" ? "删除该条目" : o.Text("new_text"))).ToList();
        return [("当前简历内容", "候选简历内容")];
    }

    void Advance(JsonNode selected, int index)
    {
        var rest = _o.Proposals.Where(p => p.Text("status") == "pending" && p.Text("id") != selected.Text("id")).ToList();
        var list = _o.Proposals.ToList();
        var next = rest.FirstOrDefault(p => list.IndexOf(p) > index) ?? rest.FirstOrDefault();
        if (next is not null) SelectedId = next.Text("id"); else Expanded = false;
    }

    FrameworkElement CardView(JsonNode selected, int index, string progressText)
    {
        var multi = _o.Proposals.Count > 1;
        var actionable = selected.Text("status") == "pending";
        var disabled = _o.Busy is not null || _o.Locked;
        var pending = Pending;
        var stack = new StackPanel { Spacing = 12 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(Sans($"{(_o.Historical ? "历史修改建议 · " : "")}{(multi ? $"建议修改 · {_o.Proposals.Count} 处" : $"建议修改 · {Short(selected, 0)}")}", 13.5, Txt, Semibold));
        if (multi || !actionable) title.Children.Add(Sans(multi ? progressText : Status(selected) ?? "", 11.5, Fnt).Align(v: VerticalAlignment.Bottom));
        stack.Children.Add(Columns(8, (Star(), title), (GridLength.Auto, Sans($"目标简历「{_o.ResumeLabel}」", 11.5, Fnt).Align(v: VerticalAlignment.Bottom))));
        if (multi)
        {
            var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            for (var i = 0; i < _o.Proposals.Count; i++)
            {
                var proposal = _o.Proposals[i];
                var active = proposal.Text("id") == selected.Text("id");
                var status = proposal.Text("status");
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
                if (status == "applied") row.Children.Add(Sans("✓", 12, Green));
                else if (status != "pending") row.Children.Add(Sans("–", 12, Fnt));
                else row.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = Brush(V3.Orange), VerticalAlignment = VerticalAlignment.Center });
                row.Children.Add(Sans(Short(proposal, i), 12));
                if (Status(proposal) is { } label) row.Children.Add(Sans(label, 10.5, Fnt).Align(v: VerticalAlignment.Center));
                var tab = new Border
                {
                    Child = row, Padding = new Thickness(10, 0, 10, 0), Height = 28, CornerRadius = new CornerRadius(7), Background = Brush(active ? Field : Clear),
                    BorderBrush = Brush(active ? Alpha(Txt, 0.35) : Cl), BorderThickness = new Thickness(1),
                }.Tip(proposal.Text("summary"));
                var id = proposal.Text("id");
                tab.OnTap(() => { SelectedId = id; Render(); }, Short(proposal, i), () => _o.Progress is null);
                if (active) AutomationProperties.SetItemStatus(tab, "已选择");
                tabs.Children.Add(tab);
            }
            stack.Children.Add(new ScrollViewer { Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        }
        foreach (var (before, after) in Changes(selected))
        {
            var change = new StackPanel { Spacing = 6 };
            var original = Sans(before, 12.5, Fnt).Wrap();
            original.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
            original.IsTextSelectionEnabled = true;
            change.Children.Add(Columns(8, (Px(28), Sans("原文", 11, Fnt)), (Star(), original)));
            var suggested = Sans(after, 12.5, Txt).Wrap();
            suggested.IsTextSelectionEnabled = true;
            change.Children.Add(Columns(8, (Px(28), Sans("建议", 11, Green)), (Star(), suggested)));
            stack.Children.Add(new Border { Child = change, Padding = new Thickness(10), Background = Brush(Stage), CornerRadius = new CornerRadius(8) });
        }
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        left.Children.Add(Sans("‹", 14, index <= 0 || _o.Progress is not null ? Fnt2 : Txt).OnTap(() => { if (index > 0) { SelectedId = _o.Proposals[index - 1].Text("id"); Render(); } }, "上一项修改", () => index > 0 && _o.Progress is null));
        left.Children.Add(Number($"{index + 1} / {_o.Proposals.Count}", 11.5, Sub, Regular).Align(v: VerticalAlignment.Center));
        left.Children.Add(Sans("›", 14, index >= _o.Proposals.Count - 1 || _o.Progress is not null ? Fnt2 : Txt).OnTap(() => { if (index < _o.Proposals.Count - 1) { SelectedId = _o.Proposals[index + 1].Text("id"); Render(); } }, "下一项修改", () => index < _o.Proposals.Count - 1 && _o.Progress is null));
        if (selected.Text("resume_id").Length > 0) left.Children.Add(Sans("在简历中预览", 12, Link).Pad(6, 0, 0, 0).Align(v: VerticalAlignment.Center).OnTap(() => _o.Preview(selected), "在简历中预览"));
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (actionable)
        {
            right.Children.Add(new V3Button("继续调整", () => _o.ContinueEditing(selected)) { Enabled = !disabled && !_o.Running });
            right.Children.Add(new V3Button("忽略", async () => { if (await _o.Reject(selected)) { Advance(selected, index); Render(); } }) { Enabled = !disabled });
            var applyTitle = _o.Busy == selected.Text("id") && _o.Progress is null ? "处理中…" : pending.Count > 1 ? "采用此项" : "采用";
            right.Children.Add(new V3Button(applyTitle, async () => { if (await _o.Apply(selected)) { Advance(selected, index); Render(); } }, pending.Count > 1 ? V3Button.Kind.Ghost : V3Button.Kind.Dark) { Enabled = !disabled && !_o.Running });
            if (pending.Count > 1 || _o.Progress is not null)
                right.Children.Add(new V3Button(_o.Progress is { } p ? $"正在采用（{p.completed}/{p.total}）" : $"全部采用（{pending.Count}）", _o.ApplyAll, V3Button.Kind.Dark) { Enabled = !disabled && !_o.Running });
        }
        else
        {
            var done = selected.Text("status") == "applied";
            right.Children.Add(Sans(done ? "✓ 已写入简历" : Status(selected) ?? "", 12, done ? Green : Fnt).Align(v: VerticalAlignment.Center));
        }
        stack.Children.Add(Columns(8, (Star(), left), (GridLength.Auto, right)));
        return Card(stack, 14, new Thickness(16));
    }
}

/// <summary>这次记下的记忆（Mac `MemoryReceipt`，Web `CitationCard` 的“这次记下”）：可逐条撤销（写入排除约束）或恢复；可收起、关闭。</summary>
public sealed class MemoryReceipt : UserControl
{
    // 父视图重画会重建本卡，按会话保存已读结果与操作状态
    static readonly Dictionary<string, (List<JsonNode> items, Dictionary<string, string> undone, bool folded, bool closed, int refresh)> Cache = [];
    readonly string _sessionId;

    public MemoryReceipt(string sessionId, int refresh)
    {
        _sessionId = sessionId;
        if (!Cache.TryGetValue(sessionId, out var state) || state.refresh != refresh)
        {
            Cache[sessionId] = (state.items ?? [], state.undone ?? [], state.folded, state.closed, refresh);
            Loaded += async (_, _) => await LoadAsync();
        }
        Render();
    }

    async Task LoadAsync()
    {
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/agent/sessions/{_sessionId}/memory/recorded");
            if (!result.Bool("enabled")) return;
            var state = Cache[_sessionId];
            Cache[_sessionId] = state with { items = result.Items("items") };
            Render();
        }
        catch { }
    }

    void Render()
    {
        var state = Cache[_sessionId];
        if (state.closed || state.items.Count == 0) { Content = null; return; }
        if (state.folded)
        {
            var chip = new Border
            {
                Child = HStack(6, Icon("brain", 11, Sub), Sans($"这次记下 {state.items.Count} 条", 12, Sub).Align(v: VerticalAlignment.Center), Icon("chevron.down", 9, Sub)),
                Padding = new Thickness(10, 0, 10, 0), Height = 26, CornerRadius = new CornerRadius(13), Background = Brush(Field), HorizontalAlignment = HorizontalAlignment.Left,
            };
            chip.OnTap(() => { Cache[_sessionId] = Cache[_sessionId] with { folded = false }; Render(); }, $"这次记下 {state.items.Count} 条");
            Content = chip;
            return;
        }
        var stack = new StackPanel { Spacing = 8 };
        var actions = HStack(8,
            Icon("chevron.up", 11, Sub).OnTap(() => { Cache[_sessionId] = Cache[_sessionId] with { folded = true }; Render(); }, "收起记下的内容"),
            Icon("xmark", 11, Sub).OnTap(() => { Cache[_sessionId] = Cache[_sessionId] with { closed = true }; Render(); }, "关闭"));
        stack.Children.Add(Spread(Sans($"这次记下 {state.items.Count} 条", 12.5, Txt, Medium), actions));
        foreach (var item in state.items)
        {
            var key = item.Text("key");
            var undone = state.undone.ContainsKey(key);
            var dot = new Ellipse { Width = 6, Height = 6, Fill = Brush(undone ? Fnt2 : V3.Blue), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 0, 0) };
            var text = Sans(undone ? "已撤销，这条不会记下" : item.Text("value").NonEmpty() ?? item.Text("quote").NonEmpty() ?? item.Text("label"), 12.5, undone ? Fnt : Txt).Wrap();
            var toggle = Sans(undone ? "恢复" : "撤销", 12, Link).OnTap(() => _ = ToggleAsync(item), undone ? "恢复" : "撤销");
            stack.Children.Add(Columns(8, (GridLength.Auto, dot), (Star(), text), (GridLength.Auto, toggle)));
        }
        Content = Card(stack, 12, new Thickness(14));
    }

    async Task ToggleAsync(JsonNode item)
    {
        var key = item.Text("key");
        var undone = Cache[_sessionId].undone;
        try
        {
            if (undone.TryGetValue(key, out var id))
            {
                await App.Session.Api.CareerRequestAsync($"/api/memory/constraints/{id}", "DELETE");
                undone.Remove(key);
            }
            else
            {
                var created = await App.Session.Api.CareerRequestAsync("/api/memory/constraints", "POST",
                    body: new JsonObject { ["kind"] = "exclude", ["target"] = new JsonObject { ["target"] = item.Text("delete") } });
                undone[key] = created.Text("id");
            }
        }
        catch { }
        Render();
    }
}

/// <summary>上下文用量圆环与浮层（Mac `ContextUsageRing`，Web `ContextUsage.tsx`）：离自动整理还有多远、各类占比、整理较早对话。</summary>
public static class ContextUsageRing
{
    public const double Reserve = 16_384;
    public const double MaxWindow = 200_000;
    static readonly (string key, string name, Color color)[] Categories =
    [
        ("conversation", "对话记录", V3.Blue), ("materials", "引用资料", Green), ("memory", "求职记忆", Purple),
        ("attachments", "附件", V3.Orange), ("system", "系统指令与工具", Hex(0xA8A49A)),
    ];

    public static string Format(double value)
    {
        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        if (value < 1000) return ((int)value).ToString(invariant);
        if (value < 1_000_000) return value < 10_000 ? (value / 1000).ToString("0.0", invariant).Replace(".0", "") + "k" : $"{(int)Math.Round(value / 1000)}k";
        return (value / 1_000_000).ToString("0.0", invariant) + "M";
    }

    public static FrameworkElement? Make(JsonNode? usage, string? modelName, bool open, Action<bool> setOpen, bool compactDisabled, Action compact)
    {
        if (usage.Number("context_window") is not { } window) return null;
        var limit = Math.Min(window, MaxWindow);
        var compactAt = Math.Max(1, limit - Reserve);
        var tokens = usage.Number("tokens");
        double? percent = tokens is { } t ? Math.Min(100, Math.Round(t / compactAt * 1000) / 10) : null;
        var label = percent is { } p ? $"距自动压缩已用 {(int)Math.Round(p)}%" : "上下文已压缩，下次回复后更新用量";
        var ring = new Grid { Width = 16, Height = 16, Padding = new Thickness(1), VerticalAlignment = VerticalAlignment.Center };
        ring.Children.Add(new Ellipse { Stroke = Brush(Cl), StrokeThickness = 2 });
        if (percent is > 0)
        {
            // 从 12 点开始顺时针的弧（`Circle().trim(from: 0, to:)` + `rotationEffect(-90°)`）
            var draw = new global::DrawOffer.App.DesignSystem.Draw(14, 14);
            var sweep = Math.Min(359.9, percent.Value / 100 * 360) * Math.PI / 180;
            var center = new Point(7, 7);
            const double r = 6;
            var start = new Point(center.X, center.Y - r);
            var end = new Point(center.X + r * Math.Sin(sweep), center.Y - r * Math.Cos(sweep));
            var figure = new PathFigure { StartPoint = start, IsClosed = false, IsFilled = false };
            figure.Segments.Add(new ArcSegment { Point = end, Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise, IsLargeArc = sweep > Math.PI });
            draw.Stroke(new PathGeometry { Figures = { figure } }, percent >= 80 ? V3.Orange : Txt, 2, round: true);
            ring.Children.Add(draw.Surface);
        }
        ToolTipService.SetToolTip(ring, label);
        ring.OnTap(() => Show(ring, usage, modelName, limit, compactAt, tokens, percent, compactDisabled, compact, setOpen), label);
        if (open) ring.Loaded += (_, _) => Show(ring, usage, modelName, limit, compactAt, tokens, percent, compactDisabled, compact, setOpen);
        return ring;
    }

    static void Show(FrameworkElement anchor, JsonNode? usage, string? modelName, double limit, double compactAt, double? tokens, double? percent, bool compactDisabled, Action compact, Action<bool> setOpen)
    {
        var stack = new StackPanel { Spacing = 10, Width = 300 - 28 };
        Flyout? flyout = null;
        if (tokens is { } used && percent is { } p)
        {
            stack.Children.Add(Sans(used >= compactAt ? $"已用 {Format(used)}，即将自动整理" : $"已用 {Format(used)}，离自动整理还有 {Format(compactAt - used)}", 13, Txt, Medium));
            var breakdown = usage.Get("breakdown") as JsonObject;
            var bar = new StackPanel { Orientation = Orientation.Horizontal };
            var track = new Grid { Height = 6, CornerRadius = new CornerRadius(3), Background = Brush(Field) };
            track.Children.Add(bar);
            var width = 300 - 28;
            if (breakdown is not null)
                foreach (var (key, _, color) in Categories)
                {
                    var value = breakdown.Number(key) ?? 0;
                    if (value > 0) bar.Children.Add(new Border { Width = width * Math.Min(1, value / compactAt), Background = Brush(color) });
                }
            else bar.Children.Add(new Border { Width = width * Math.Min(1, used / compactAt), Background = Brush(V3.Blue) });
            stack.Children.Add(track);
            stack.Children.Add(Spread(Number($"{(int)Math.Round(p)}%", 10.5, Fnt, Regular), Number(Format(compactAt), 10.5, Fnt, Regular)));
            if (breakdown is not null)
                foreach (var (key, name, color) in Categories)
                    if (breakdown.Number(key) is { } value && value > 0)
                        stack.Children.Add(Columns(6, (GridLength.Auto, new Ellipse { Width = 7, Height = 7, Fill = Brush(color), VerticalAlignment = VerticalAlignment.Center }),
                            (Star(), Sans(name, 12)), (GridLength.Auto, Number(Format(value), 11.5, Sub, Regular))));
        }
        else
        {
            stack.Children.Add(Sans("较早的对话已整理成摘要", 13, Txt, Medium));
            stack.Children.Add(Sans("下次回复后重新计算用量；引用的资料、记忆和附件仍可随时读取。", 12, Sub).Wrap());
        }
        stack.Children.Add(Divider());
        var footLeft = Number(string.Join(" · ", new[] { modelName, $"上限 {Format(limit)}" }.OfType<string>()), 11, Fnt, Regular);
        UIElement footRight = tokens is not null
            ? Sans("整理较早对话", 12, compactDisabled ? Fnt2 : Link).OnTap(() => { flyout?.Hide(); compact(); }, "整理较早对话", () => !compactDisabled)
            : new Border();
        stack.Children.Add(Spread(footLeft, footRight));
        flyout = V3Popover.Show(anchor, stack, Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top, padding: 14);
        setOpen(true);
        flyout.Closed += (_, _) => setOpen(false);
    }
}

/// <summary>引用已有资料（Mac `ReferencePicker`）：搜索、按类型筛选、多选后“添加 N 项”。</summary>
public static class ReferencePicker
{
    public static FrameworkElement Make(IReadOnlyList<JsonNode> groups, IReadOnlyList<JsonNode> chosen, Func<string, string> label, Action<List<JsonNode>> add, Action close)
    {
        var query = "";
        var type = "";
        var picked = new List<JsonNode>();
        static bool Same(JsonNode a, JsonNode b) => a.ToJsonString() == b.ToJsonString();
        var list = new StackPanel { Spacing = 2 };
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        V3Button? submit = null;
        void Fill()
        {
            list.Children.Clear();
            var items = groups.Where(g => type.Length == 0 || g.Text("type") == type).SelectMany(g => g.Items("items"))
                .Where(i => query.Length == 0 || i.Text("label").Contains(query, StringComparison.CurrentCultureIgnoreCase) || i.Text("description").Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
            if (items.Count == 0) list.Children.Add(Sans(groups.Count == 0 ? "正在读取可引用的资料…" : "没有匹配的资料", 13, Fnt).Pad(10, 8, 10, 8));
            foreach (var item in items)
            {
                var already = chosen.Any(c => Same(c, item));
                var selected = picked.Any(c => Same(c, item));
                var texts = new StackPanel { Spacing = 1 };
                texts.Children.Add(Sans(item.Text("label"), 13));
                if (item.Text("description").Length > 0) texts.Children.Add(Sans(item.Text("description"), 11.5, Fnt));
                var row = Columns(10, (GridLength.Auto, Icon(already || selected ? "checkmark.square.fill" : "square", 13, already ? Fnt : Txt).Align(v: VerticalAlignment.Center)),
                    (Star(), texts), (GridLength.Auto, Sans(label(item.Text("type")), 11, Fnt).Align(v: VerticalAlignment.Center)));
                row.Padding = new Thickness(10, 6, 10, 6);
                row.Background = Brush(Clear);
                row.OnTap(() => { if (selected) picked.RemoveAll(c => Same(c, item)); else picked.Add(item); Fill(); }, item.Text("label"), () => !already);
                list.Children.Add(row);
            }
            if (submit is not null) { submit.Title = picked.Count == 0 ? "添加" : $"添加 {picked.Count} 项"; submit.Enabled = picked.Count > 0; }
            tabs.Children.Clear();
            foreach (var (title, value) in new[] { ("全部", "") }.Concat(groups.Select(g => (label(g.Text("type")), g.Text("type")))))
            {
                var on = type == value;
                var tab = new Border { Child = Sans(title, 12, on ? V3.White : Sub).Align(v: VerticalAlignment.Center), Padding = new Thickness(10, 0, 10, 0), Height = 26, CornerRadius = new CornerRadius(13), Background = Brush(on ? Txt : Field) };
                tab.OnTap(() => { type = value; Fill(); }, title);
                tabs.Children.Add(tab);
            }
        }
        var search = new TextBox { PlaceholderText = "搜索简历、资料或岗位", FontSize = 13, FontFamily = SansFamily };
        search.TextChanged += (_, _) => { query = search.Text; Fill(); };
        submit = new V3Button("添加", () => { add(picked); close(); }, V3Button.Kind.Dark) { Enabled = false };
        Fill();
        var stack = new StackPanel { Spacing = 12, Width = 480 - 40 };
        stack.Children.Add(Serif("引用已有资料", 20));
        stack.Children.Add(search);
        stack.Children.Add(tabs);
        stack.Children.Add(new ScrollViewer { Content = list, Height = 300 });
        var foot = HStack(8, new V3Button("取消", close), submit);
        foot.HorizontalAlignment = HorizontalAlignment.Right;
        stack.Children.Add(foot);
        return Card(stack, 16, new Thickness(20), V3.White);
    }
}

/// <summary>
/// 把 AI 生成的文档以 `.md` 保存到资料库所选文件夹（Mac `SaveDocumentSheet`，Web “保存到资料库”）。重名时加时间后缀保留两份；
/// 上传使用固定标识，网络结果不确定时重试不会重复保存。
/// </summary>
public sealed class SaveDocumentDialog : UserControl
{
    readonly string _content, _title;
    readonly Action _close, _saved;
    List<JsonNode> _folders = [];
    string _folder = "";
    string _newFolder = "";
    bool _busy;
    string? _error;
    DatasetUpload? _upload;

    public SaveDocumentDialog(string content, string title, Action close, Action saved)
    {
        _content = content;
        _title = title;
        _close = close;
        _saved = saved;
        Render();
        Loaded += async (_, _) => await LoadFoldersAsync();
    }

    void Render()
    {
        var stack = new StackPanel { Spacing = 14, Width = 440 - 48 };
        stack.Children.Add(Serif("保存到资料库", 20));
        stack.Children.Add(Sans($"「{_title}」将以 Markdown 文件保存。", 13, Sub).Wrap());
        var picker = new ComboBox { PlaceholderText = "选择文件夹", HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = !_busy && _upload is null };
        foreach (var folder in _folders) picker.Items.Add(new ComboBoxItem { Content = folder.Text("name"), Tag = folder.Text("id") });
        picker.SelectedIndex = _folders.FindIndex(f => f.Text("id") == _folder);
        picker.SelectionChanged += (_, _) => { if (picker.SelectedItem is ComboBoxItem { Tag: string id }) { _folder = id; Render(); } };
        AutomationProperties.SetName(picker, "文件夹");
        stack.Children.Add(picker);
        var name = new TextBox { Text = _newFolder, PlaceholderText = "或新建文件夹", FontSize = 13 };
        name.TextChanged += (_, _) => _newFolder = name.Text;
        var create = new V3Button("新建", () => _ = CreateFolderAsync()) { Enabled = !_busy };
        stack.Children.Add(Columns(8, (Star(), name), (GridLength.Auto, create)));
        if (_error is { } error) stack.Children.Add(Sans(error, 12.5, Red).Wrap());
        var foot = HStack(8,
            new V3Button("取消", () => { _upload?.Discard(); _close(); }) { Enabled = !_busy },
            new V3Button(_busy ? "正在保存…" : "保存", () => _ = SaveAsync(), V3Button.Kind.Dark) { Enabled = !_busy && _folder.Length > 0 });
        foot.HorizontalAlignment = HorizontalAlignment.Right;
        stack.Children.Add(foot);
        Content = Card(stack, 16, new Thickness(24), V3.White);
    }

    async Task LoadFoldersAsync()
    {
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/datasets/folders");
            var folders = result.Items("folders");
            _folders = (folders.Count > 0 ? folders : result.Items("items")).Where(f => f.Text("id").Length > 0).ToList();
            if (_folder.Length == 0) _folder = _folders.FirstOrDefault()?.Text("id") ?? "";
        }
        catch { _error = "文件夹读取失败，请稍后重试。"; }
        Render();
    }

    async Task CreateFolderAsync()
    {
        if (_newFolder.Trim().Length == 0) return;
        _busy = true;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/datasets/folders", "POST", body: new JsonObject { ["name"] = _newFolder.Trim() });
            _newFolder = "";
            await LoadFoldersAsync();
            if ((result.Get("folder") ?? result).Get("id").String() is { } id) _folder = id;
        }
        catch { _error = "新建文件夹失败，可能已有同名文件夹。"; }
        finally { _busy = false; Render(); }
    }

    async Task SaveAsync()
    {
        _busy = true;
        _error = null;
        Render();
        try
        {
            if (_upload is null || _upload.Folder != _folder)
            {
                _upload?.Discard();
                var safe = new string(_title.Select(c => "/:\\\0".Contains(c) ? '-' : c).Take(80).ToArray());
                var directory = DatasetUpload.PrivateDirectory();
                try
                {
                    var source = System.IO.Path.Combine(directory, safe + ".md");
                    await File.WriteAllTextAsync(source, _content, new System.Text.UTF8Encoding(false));
                    _upload = DatasetUpload.Snapshot(source, _folder, 50 * 1024 * 1024);
                }
                finally { try { Directory.Delete(directory, true); } catch { } }
            }
            var current = _upload!;
            try { await App.Session.Api.UploadDatasetAsync(current); }
            catch (ApiException error) when (error.Code is "DATASET_NAME_CONFLICT" or "DATASET_FILENAME_CONFLICT")
            {
                current = current with { Id = Guid.NewGuid().ToString("D"), Name = _title + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".md" };
                _upload = current;
                await App.Session.Api.UploadDatasetAsync(current);
            }
            current.Discard();
            _upload = null;
            _saved();
            _close();
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = "保存失败：结果尚未确认时可直接重试，不会重复保存。";
        }
        finally { _busy = false; Render(); }
    }
}
