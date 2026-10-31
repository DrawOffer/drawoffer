using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 简历正文的原生富文本编辑（Mac `RichTextEditor.swift`）：RichEditBox 与 canonical runs 双向转换。
/// Mac 把格式的“真值”存在 NSAttributedString 的自定义属性里；RichEditBox 没有自定义属性，这里改为从显示格式反推：
/// 加粗 / 斜体 / 下划线 / 删除线读字符格式，代码读等宽字体，链接读 ITextRange.Link，颜色与高亮读前景 / 背景色（与默认色不同才算），
/// 字号读 Size / 1.25。图标以 Segoe Fluent 字形保留，按字形反查名字；行内图片按出现顺序保留原始 JSON。粘贴一律按纯文本。
/// </summary>
public static class RichRuns
{
    public const double BaseSize = 13;
    public static readonly string[] MarkOrder = ["bold", "italic", "underline", "strike", "code"];
    const string CodeFont = "Cascadia Mono,Consolas";
    static readonly Color DefaultInk = Txt;
    static readonly Color LinkInk = Link;
    /// <summary>Mac `NSColor.quaternaryLabelColor` 的近似：代码底色。</summary>
    static readonly Color CodeBackground = Hex(0xEBEBEF);

    public static string IconSymbol(string name) => name switch
    {
        "Mail" => "envelope", "Phone" => "phone", "MapPin" => "mappin.and.ellipse", "Globe" => "globe",
        "Github" => "chevron.left.forwardslash.chevron.right", "Linkedin" => "person.crop.square", "GraduationCap" => "graduationcap",
        "Briefcase" => "briefcase", "Award" => "rosette", "Star" => "star", "Calendar" => "calendar", "Code2" => "curlybraces",
        _ => "questionmark.square",
    };

    /// <summary>字形 → 图标名（同一字形对应多个名字时取 IconNames 里靠前的一个）。</summary>
    static string? IconName(string glyph) => ResumeDocument.IconNames.FirstOrDefault(name => Icons.Glyph(IconSymbol(name)) == glyph);

    public static Color? ParseHex(string? hex)
    {
        if (hex is not { Length: 7 } || hex[0] != '#' || !uint.TryParse(hex[1..], System.Globalization.NumberStyles.HexNumber, null, out var value)) return null;
        return Hex(value);
    }

    static string HexText(Color color) => $"#{color.R:x2}{color.G:x2}{color.B:x2}";

    /// <summary>Mac `RichRuns.display`：由语义计算显示格式，写到一段范围上。</summary>
    internal static void Display(ITextCharacterFormat format, IReadOnlySet<string> marks, string? href, string? color, string? highlight, double? size)
    {
        format.Size = (float)(size is { } pt ? Math.Min(40, Math.Max(9, pt * 1.25)) : BaseSize);
        format.Name = marks.Contains("code") ? CodeFont : "Segoe UI";
        format.Bold = marks.Contains("bold") ? FormatEffect.On : FormatEffect.Off;
        format.Italic = marks.Contains("italic") ? FormatEffect.On : FormatEffect.Off;
        format.Underline = marks.Contains("underline") || href is not null ? UnderlineType.Single : UnderlineType.None;
        format.Strikethrough = marks.Contains("strike") ? FormatEffect.On : FormatEffect.Off;
        format.ForegroundColor = ParseHex(color) ?? (href is not null ? LinkInk : DefaultInk);
        format.BackgroundColor = ParseHex(highlight) ?? (marks.Contains("code") ? CodeBackground : Microsoft.UI.Colors.Transparent);
    }

    /// <summary>runs → 文档内容；返回行内图片的原始 JSON（按出现顺序）。</summary>
    public static List<JsonNode> Write(RichEditBox box, IEnumerable<JsonNode?> runs)
    {
        var document = box.Document;
        var images = new List<JsonNode>();
        document.SetText(TextSetOptions.None, "");
        foreach (var run in runs)
        {
            var end = document.GetRange(0, int.MaxValue).EndPosition;
            var range = document.GetRange(end, end);
            if (run.Text("inline_type") == "text")
            {
                var text = run.Text("text");
                if (text.Length == 0) continue;
                range.Text = text;
                var marks = run.Items("marks").Select(x => x.String()).OfType<string>().ToHashSet();
                var href = run.Get("href").String();
                Display(range.CharacterFormat, marks, href, run.Get("style").Get("color").String(), run.Get("style").Get("highlight_color").String(), run.Get("style").Number("font_size_pt"));
                if (href is not null) range.Link = $"\"{href}\"";
            }
            else
            {
                var icon = run.Text("inline_type") == "icon";
                range.Text = Icons.Glyph(icon ? IconSymbol(run.Text("name")) : "photo");
                range.CharacterFormat.Name = IconFamily.Source;
                range.CharacterFormat.Size = (float)(BaseSize - 1);
                range.CharacterFormat.ForegroundColor = Fnt;
                if (!icon && run is not null) images.Add(run.DeepClone());
            }
        }
        return images;
    }

    /// <summary>文档内容 → canonical runs（逐字读格式，相同格式的相邻文字合并，最后经 Core `NormalizeRuns`）。</summary>
    public static List<JsonNode?> Read(RichEditBox box, IReadOnlyList<JsonNode> images)
    {
        var document = box.Document;
        document.GetText(TextGetOptions.None, out var all);
        // RichEditBox 总在末尾带一个段落符
        if (all.EndsWith('\r')) all = all[..^1];
        var result = new List<JsonNode?>();
        var imageIndex = 0;
        for (var i = 0; i < all.Length; i++)
        {
            var range = document.GetRange(i, i + 1);
            var format = range.CharacterFormat;
            var piece = all[i] == '\r' ? "\n" : all[i].ToString();
            if (format.Name == IconFamily.Source)
            {
                if (piece == Icons.Glyph("photo") && imageIndex < images.Count) result.Add(images[imageIndex++].DeepClone());
                else if (IconName(piece) is { } name) result.Add(new JsonObject { ["inline_type"] = "icon", ["name"] = name });
                continue;
            }
            var marks = new List<string>();
            if (format.Bold == FormatEffect.On) marks.Add("bold");
            if (format.Italic == FormatEffect.On) marks.Add("italic");
            var link = range.Link.Trim('"');
            var href = link.Length > 0 ? link : null;
            if (format.Underline != UnderlineType.None && href is null) marks.Add("underline");
            if (format.Strikethrough == FormatEffect.On) marks.Add("strike");
            var code = format.Name == CodeFont || format.Name.StartsWith("Cascadia", StringComparison.Ordinal) || format.Name == "Consolas";
            if (code) marks.Add("code");
            var ink = format.ForegroundColor;
            string? color = ink == DefaultInk || (href is not null && ink == LinkInk) ? null : HexText(ink);
            var back = format.BackgroundColor;
            string? highlight = back.A == 0 || (code && back == CodeBackground) ? null : HexText(back);
            double? size = Math.Abs(format.Size - BaseSize) < 0.01 ? null : Math.Round(format.Size / 1.25 * 2, MidpointRounding.AwayFromZero) / 2;
            result.Add(ResumeDocument.TextRun(piece, MarkOrder.Where(marks.Contains), href, color, highlight, size));
        }
        return ResumeDocument.NormalizeRuns(result);
    }
}

// MARK: - Controller shared by the toolbar and every field

/// <summary>当前获得焦点的富文本框与选区格式（Mac `RichTextController`）。格式工具条通过它作用于选区（无选区时作用于接下来输入的文字）。</summary>
public sealed class RichTextController
{
    public sealed record Selection(IReadOnlySet<string> Marks, string? Href, string? Color, string? Highlight, double? Size, bool HasRange, bool AllowsInline)
    {
        public static readonly Selection Empty = new(new HashSet<string>(), null, null, null, null, false, false);
    }

    public static readonly string[] TextColors = ["#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#3478f6", "#af52de", "#8a8a8e"];
    public static readonly string[] HighlightColors = ["#fff3c4", "#d1f5db", "#dbe8ff", "#ffe0d1", "#f3e3ff", "#f0f0f0", "#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#3478f6", "#af52de", "#8a8a8e"];
    public static readonly (double Min, double Max, double Step) SizeRange = (6.0, 48.0, 0.5);

    internal RichTextField? TextView { get; private set; }
    public bool Active { get; private set; }
    public Selection Current { get; private set; } = Selection.Empty;
    public event Action? Changed;

    internal void Focus(RichTextField view) { TextView = view; Active = true; Refresh(); }

    /// <summary>失焦后仍以最后编辑的文本框为目标：点工具条、打开链接弹层都会让文本框暂时失焦，选区仍保留。</summary>
    internal void Blur(RichTextField view)
    {
        if (TextView != view) return;
        Active = view.XamlRoot is not null;
        Changed?.Invoke();
    }

    internal void Detach(RichTextField view)
    {
        if (TextView != view) return;
        TextView = null; Active = false; Current = Selection.Empty;
        Changed?.Invoke();
    }

    public void Refresh()
    {
        if (TextView is not { } view) { Current = Selection.Empty; Changed?.Invoke(); return; }
        var selection = view.Box.Document.Selection;
        var probe = selection.Length > 0 ? view.Box.Document.GetRange(selection.StartPosition, selection.StartPosition + 1) : selection;
        var format = probe.CharacterFormat;
        var marks = new HashSet<string>();
        var link = selection.Length > 0 ? probe.Link.Trim('"') : "";
        if (format.Bold == FormatEffect.On) marks.Add("bold");
        if (format.Italic == FormatEffect.On) marks.Add("italic");
        if (format.Underline != UnderlineType.None && link.Length == 0) marks.Add("underline");
        if (format.Strikethrough == FormatEffect.On) marks.Add("strike");
        if (format.Name.StartsWith("Cascadia", StringComparison.Ordinal) || format.Name == "Consolas") marks.Add("code");
        var ink = format.ForegroundColor;
        string? color = ink == Txt || ink == Link ? null : $"#{ink.R:x2}{ink.G:x2}{ink.B:x2}";
        var back = format.BackgroundColor;
        string? highlight = back.A == 0 || back == Hex(0xEBEBEF) ? null : $"#{back.R:x2}{back.G:x2}{back.B:x2}";
        double? size = Math.Abs(format.Size - RichRuns.BaseSize) < 0.01 ? null : Math.Round(format.Size / 1.25 * 2, MidpointRounding.AwayFromZero) / 2;
        Current = new Selection(marks, link.Length > 0 ? link : null, color, highlight, size, selection.Length > 0, view.AllowsInline);
        Changed?.Invoke();
    }

    public void Toggle(string mark)
    {
        var enable = !Current.Marks.Contains(mark);
        Edit((marks, _) => { if (enable) marks.Add(mark); else marks.Remove(mark); });
    }

    public void SetLink(string? href)
    {
        if (TextView is not { } view) return;
        var selection = view.Box.Document.Selection;
        if (selection.Length == 0) return;
        selection.Link = href is null ? "" : $"\"{href}\"";
        Edit((_, state) => state.Href = href);
    }

    public void SetColor(string? color) => Edit((_, state) => state.Color = color);
    public void SetHighlight(string? color) => Edit((_, state) => state.Highlight = color);

    public void AdjustSize(double direction)
    {
        var current = Current.Size ?? 12;
        var next = Math.Min(SizeRange.Max, Math.Max(SizeRange.Min, Math.Round((current + direction * SizeRange.Step) * 2, MidpointRounding.AwayFromZero) / 2));
        Edit((_, state) => state.Size = next);
    }

    public void ClearSize() => Edit((_, state) => state.Size = null);

    public void ClearFormatting() => Edit((marks, state) => { marks.Clear(); state.Href = null; state.Color = null; state.Highlight = null; state.Size = null; });

    public void InsertIcon(string name)
    {
        if (TextView is not { } view || !view.AllowsInline) return;
        var selection = view.Box.Document.Selection;
        selection.Text = Icons.Glyph(RichRuns.IconSymbol(name));
        selection.CharacterFormat.Name = IconFamily.Source;
        selection.CharacterFormat.Size = (float)(RichRuns.BaseSize - 1);
        selection.CharacterFormat.ForegroundColor = Fnt;
        selection.Collapse(false);
        view.Box.Focus(FocusState.Programmatic);
        view.Commit();
    }

    sealed class State { public string? Href, Color, Highlight; public double? Size; }

    /// <summary>改写选区内每段文字的语义格式；无选区时改写接下来输入的文字（RichEditBox 的插入点格式）。图标与图片不受影响。</summary>
    void Edit(Action<HashSet<string>, State> change)
    {
        if (TextView is not { } view) return;
        var document = view.Box.Document;
        var selection = document.Selection;
        void Apply(ITextRange range, ITextCharacterFormat format)
        {
            var marks = new HashSet<string>(Current.Marks);
            var link = range.Length > 0 ? document.GetRange(range.StartPosition, range.StartPosition + 1).Link.Trim('"') : "";
            var state = new State { Href = link.Length > 0 ? link : Current.Href, Color = Current.Color, Highlight = Current.Highlight, Size = Current.Size };
            change(marks, state);
            RichRuns.Display(format, marks, state.Href, state.Color, state.Highlight, state.Size);
        }
        if (selection.Length == 0) { Apply(selection, selection.CharacterFormat); Refresh(); return; }
        document.BeginUndoGroup();
        for (var i = selection.StartPosition; i < selection.EndPosition; i++)
        {
            var range = document.GetRange(i, i + 1);
            if (range.CharacterFormat.Name == IconFamily.Source) continue;
            Apply(range, range.CharacterFormat);
        }
        document.EndUndoGroup();
        view.Box.Focus(FocusState.Programmatic);
        view.Commit();
        Refresh();
    }
}

// MARK: - Field

/// <summary>
/// Mac `RichNSTextView` + `RichTextField`：`Runs` 是 canonical inline 数组；高度随内容增长。
/// 单行模式把换行压成空格；有 onReturn 时回车交给它；粘贴按纯文本。
/// </summary>
public sealed class RichTextField : UserControl
{
    internal RichEditBox Box { get; } = new();
    internal List<JsonNode> Images { get; private set; } = [];
    readonly RichTextController _controller;
    readonly Action<List<JsonNode?>> _changed;
    List<JsonNode?> _last = [];
    bool _writing;

    public bool SingleLine { get; set; }
    /// <summary>段落与列表项允许图标、行内图片；textValue 字段只允许文字。</summary>
    public bool AllowsInline { get; set; }
    public Action? OnReturn { get; set; }

    public RichTextField(IReadOnlyList<JsonNode?> runs, Action<List<JsonNode?>> changed, RichTextController controller, string placeholder = "", bool singleLine = false,
        bool allowsInline = false, double minHeight = 26, Action? onReturn = null)
    {
        _controller = controller;
        _changed = changed;
        SingleLine = singleLine;
        AllowsInline = allowsInline;
        OnReturn = onReturn;
        Box.PlaceholderText = placeholder;
        Box.MinHeight = minHeight;
        Box.Padding = new Thickness(4, 5, 4, 5);
        Box.FontSize = RichRuns.BaseSize;
        Box.TextWrapping = TextWrapping.Wrap;
        Box.IsSpellCheckEnabled = false;
        Box.IsTextPredictionEnabled = false;
        Box.Background = Brush(Clear);
        Box.BorderThickness = new Thickness(0);
        Box.ClipboardCopyFormat = RichEditClipboardFormat.PlainText;
        foreach (var key in new[] { "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" })
            Box.Resources[key] = Brush(Clear);
        Content = Box;
        SetRuns(runs);
        Box.TextChanged += (_, _) => { if (!_writing) Commit(); };
        Box.SelectionChanged += (_, _) => { if (_controller.TextView == this) _controller.Refresh(); };
        Box.GotFocus += (_, _) => _controller.Focus(this);
        Box.LostFocus += (_, _) => _controller.Blur(this);
        Box.Paste += OnPaste;
        Box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            if (OnReturn is { } action) { e.Handled = true; action(); }
            else if (SingleLine) e.Handled = true;
        };
        Unloaded += (_, _) => _controller.Detach(this);
    }

    /// <summary>外部改了 runs（Mac `updateNSView`）：内容不同才重写，光标放回原位置附近。</summary>
    public void SetRuns(IReadOnlyList<JsonNode?> runs)
    {
        if (runs.Count == _last.Count && runs.Zip(_last).All(x => JsonNode.DeepEquals(x.First, x.Second))) return;
        var position = Box.Document.Selection.StartPosition;
        _writing = true;
        Images = RichRuns.Write(Box, runs);
        _writing = false;
        _last = runs.Select(x => x?.DeepClone()).ToList();
        var length = Box.Document.GetRange(0, int.MaxValue).EndPosition;
        Box.Document.Selection.SetRange(Math.Min(position, length), Math.Min(position, length));
    }

    internal void Commit()
    {
        var next = RichRuns.Read(Box, Images);
        _last = next;
        _changed(next);
        _controller.Refresh();
    }

    /// <summary>粘贴一律按纯文本，避免带入无法保存的样式；单行模式把换行压成空格。</summary>
    async void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        if (!content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
        var text = await content.GetTextAsync();
        if (SingleLine) text = Regex.Replace(text, @"\r\n|[\r\n  \u0085]", " ");
        var selection = Box.Document.Selection;
        selection.Text = text.Replace("\r\n", "\r").Replace('\n', '\r');
        selection.Collapse(false);
    }
}

// MARK: - Toolbar

/// <summary>
/// 选区格式工具条（Mac `RichTextToolbar`，Web `WorkbenchToolbar` 的选区工具）：加粗、斜体、下划线、删除线、代码、
/// 字号、文字颜色、背景色、链接、图标与清除格式。Ctrl+B / Ctrl+I / Ctrl+U 由 RichEditBox 自带处理，结果同样回到 runs。
/// </summary>
public sealed class RichTextToolbar : UserControl
{
    readonly RichTextController _controller;
    string _linkDraft = "";

    public RichTextToolbar(RichTextController controller)
    {
        _controller = controller;
        controller.Changed += () => DispatcherQueue.TryEnqueue(Render);
        Render();
    }

    void Render()
    {
        var selection = _controller.Current;
        var active = _controller.Active;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(MarkButton("bold", "bold", "加粗（Ctrl+B）"));
        row.Children.Add(MarkButton("italic", "italic", "斜体（Ctrl+I）"));
        row.Children.Add(MarkButton("underline", "underline", "下划线（Ctrl+U）"));
        row.Children.Add(MarkButton("strike", "strikethrough", "删除线"));
        row.Children.Add(MarkButton("code", "chevron.left.forwardslash.chevron.right", "代码"));
        row.Children.Add(Divider(vertical: true).Frame(height: 16));
        row.Children.Add(IconButton("textformat.size.smaller", "减小字号", () => _controller.AdjustSize(-1), selection.HasRange));
        var size = Number(selection.Size is { } pt ? (pt % 1 == 0 ? $"{pt:0}pt" : $"{pt:0.0}pt") : "默认", 11.5, Sub, Regular);
        size.MinWidth = 40;
        size.TextAlignment = TextAlignment.Center;
        size.VerticalAlignment = VerticalAlignment.Center;
        var sizeMenu = new MenuFlyout();
        var reset = new MenuFlyoutItem { Text = "恢复默认字号" };
        reset.Click += (_, _) => _controller.ClearSize();
        sizeMenu.Items.Add(reset);
        size.ContextFlyout = sizeMenu;
        row.Children.Add(size);
        row.Children.Add(IconButton("textformat.size.larger", "增大字号", () => _controller.AdjustSize(1), selection.HasRange));
        row.Children.Add(Divider(vertical: true).Frame(height: 16));
        row.Children.Add(ColorMenu("文字颜色", "character", RichTextController.TextColors, selection.Color, _controller.SetColor));
        row.Children.Add(ColorMenu("背景颜色", "highlighter", RichTextController.HighlightColors, selection.Highlight, _controller.SetHighlight));
        var link = IconButton("link", selection.Href is null ? "添加链接" : "编辑链接", () => { }, true, selection.Href is null ? Txt : Blue);
        link.OnTap(() => { _linkDraft = selection.Href ?? "https://"; V3Popover.Show(link, LinkEditor(), FlyoutPlacementMode.Bottom, 0); });
        row.Children.Add(link);
        var star = IconButton("star.square", "插入图标", () => { }, selection.AllowsInline);
        star.OnTap(() =>
        {
            var menu = new MenuFlyout();
            foreach (var name in ResumeDocument.IconNames)
            {
                var item = new MenuFlyoutItem { Text = name, Icon = new FontIcon { Glyph = Icons.Glyph(RichRuns.IconSymbol(name)), FontFamily = IconFamily } };
                var chosen = name;
                item.Click += (_, _) => _controller.InsertIcon(chosen);
                menu.Items.Add(item);
            }
            menu.ShowAt(star);
        }, enabled: () => _controller.Current.AllowsInline);
        row.Children.Add(star);
        row.Children.Add(IconButton("eraser", "清除格式", _controller.ClearFormatting, true));
        row.IsHitTestVisible = active;
        row.Opacity = active ? 1 : 0.45;
        Content = row;
    }

    FrameworkElement MarkButton(string mark, string symbol, string label)
    {
        var on = _controller.Current.Marks.Contains(mark);
        var button = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(5), Background = Brush(on ? Alpha(Blue, 0.14) : Clear),
            Child = Icon(symbol, 13, Txt).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.Tip(label);
        button.OnTap(() => _controller.Toggle(mark), label);
        if (on) AutomationProperties.SetItemStatus(button, "已选中");
        return button;
    }

    static Border IconButton(string symbol, string label, Action action, bool enabled, Color? color = null)
    {
        var button = new Border
        {
            Width = 22, Height = 22, Background = Brush(Clear), Opacity = enabled ? 1 : 0.45,
            Child = Icon(symbol, 13, color ?? Txt).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.Tip(label);
        button.OnTap(action, label, () => enabled);
        return button;
    }

    FrameworkElement ColorMenu(string title, string symbol, string[] colors, string? current, Action<string?> set)
    {
        var button = IconButton(symbol, title, () => { }, true, RichRuns.ParseHex(current) ?? Txt);
        button.OnTap(() =>
        {
            var menu = new MenuFlyout();
            var none = new MenuFlyoutItem { Text = "无" };
            none.Click += (_, _) => set(null);
            menu.Items.Add(none);
            foreach (var hex in colors)
            {
                var swatch = new FontIcon { Glyph = "", FontFamily = IconFamily, Foreground = Brush(RichRuns.ParseHex(hex) ?? Clear) };
                var item = new MenuFlyoutItem { Text = hex, Icon = swatch };
                var chosen = hex;
                item.Click += (_, _) => set(chosen);
                menu.Items.Add(item);
            }
            menu.ShowAt(button);
        }, title);
        return button;
    }

    FrameworkElement LinkEditor()
    {
        var root = new StackPanel { Spacing = 10, Padding = new Thickness(14) };
        var box = new TextBox { Text = _linkDraft, PlaceholderText = "https://", Width = 260 };
        var error = Sans("只支持 http:// 或 https:// 开头的地址", 11, Red);
        bool Valid() => Regex.IsMatch(box.Text, @"^https?://\S{1,2040}$");
        var apply = new V3Button("应用", () => { _controller.SetLink(box.Text); Close(); }, V3Button.Kind.Dark, height: 28, small: true);
        void Paint()
        {
            apply.Enabled = Valid();
            error.Visibility = !Valid() && box.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        box.TextChanged += (_, _) => { _linkDraft = box.Text; Paint(); };
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter && Valid()) { e.Handled = true; _controller.SetLink(box.Text); Close(); } };
        var buttons = HStack(8);
        if (_controller.Current.Href is not null) buttons.Children.Add(new V3Button("移除链接", () => { _controller.SetLink(null); Close(); }, V3Button.Kind.Danger, height: 28, small: true));
        var actions = Spread(buttons, HStack(8, new V3Button("取消", Close, V3Button.Kind.Ghost, height: 28, small: true), apply), 8);
        root.Children.Add(Sans("链接地址", 12.5, Txt, Medium));
        root.Children.Add(box);
        root.Children.Add(actions);
        root.Children.Add(error);
        Paint();
        return root;
        void Close()
        {
            for (DependencyObject? node = root; node is not null; node = VisualTreeHelper.GetParent(node))
                if (node is Popup popup) { popup.IsOpen = false; return; }
        }
    }
}
