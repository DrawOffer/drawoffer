using System.Text.RegularExpressions;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

/// <summary>
/// 只读的原生 Markdown（Mac `NativeMarkdownView.swift`）：不执行 HTML、不拉远程图片、不跑内嵌脚本。
/// 分块规则与 Mac 一致：代码块（mermaid 标注不执行）、带 `---` 分隔行的表格、1–6 级标题、图片占位、其余按行成段；最多 50 万字符、5000 块。
/// </summary>
public static class NativeMarkdownView
{
    sealed record Block(string Kind, string Text, List<List<string>> Rows, int Level);

    /// <param name="size">正文字号；对话回复用 Web `.assistant-message-content` 的 16。</param>
    /// <param name="line">正文行高；0 表示字号 × 1.2。</param>
    public static FrameworkElement Render(string source, double size = 13, double line = 0)
    {
        var limited = source.Length > 500_000 ? source[..500_000] : source;
        var characterTruncated = limited.Length < source.Length;
        var lines = limited.Split('\n');
        var blocks = new List<Block>();
        var index = 0;
        static List<string> Cells(string row)
        {
            var parts = row.Split('|').Select(p => p.Trim()).ToList();
            if (parts.Count > 0 && parts[0] == "") parts.RemoveAt(0);
            if (parts.Count > 0 && parts[^1] == "") parts.RemoveAt(parts.Count - 1);
            return parts.Take(20).ToList();
        }
        while (index < lines.Length && blocks.Count < 5000)
        {
            var current = lines[index];
            var trim = current.Trim();
            if (trim.StartsWith("```", StringComparison.Ordinal))
            {
                var language = trim[3..];
                var content = new List<string>();
                index++;
                while (index < lines.Length && !lines[index].Trim().StartsWith("```", StringComparison.Ordinal)) { content.Add(lines[index]); index++; }
                blocks.Add(new Block("code", string.Join("\n", content), [], language == "mermaid" ? 1 : 0));
                index++;
                continue;
            }
            if (index + 1 < lines.Length && current.Contains('|') && lines[index + 1].Contains("---"))
            {
                var rows = new List<List<string>> { Cells(current) };
                index += 2;
                while (index < lines.Length && lines[index].Contains('|') && lines[index].Length > 0) { rows.Add(Cells(lines[index])); index++; }
                blocks.Add(new Block("table", "", rows, 0));
                continue;
            }
            var level = trim.TakeWhile(c => c == '#').Count();
            var kind = level is > 0 and <= 6 && trim[level..].StartsWith(' ') ? "heading" : trim.StartsWith("![", StringComparison.Ordinal) ? "image" : "text";
            if (trim.Length > 0)
                blocks.Add(new Block(kind, kind == "heading" ? trim[(level + 1)..] : trim.StartsWith("- ", StringComparison.Ordinal) ? "• " + trim[2..] : trim, [], level));
            index++;
        }
        var truncated = characterTruncated || index < lines.Length;

        var panel = new StackPanel { Spacing = line > 0 ? 10 : 12 };
        if (truncated) panel.Children.Add(Label("正文较长，预览显示前 50 万字符；完整内容请下载原文件查看。", 12, Hex(0xFF9500)).Wrap());
        foreach (var block in blocks)
        {
            switch (block.Kind)
            {
                case "heading":
                {
                    var text = Label(block.Text, Math.Max(14, 25 - block.Level * 2.0), Txt, Semibold).Wrap();
                    text.IsTextSelectionEnabled = true;
                    panel.Children.Add(text.Top(8));
                    break;
                }
                case "code":
                {
                    var stack = new StackPanel { Spacing = 8 };
                    if (block.Level == 1) stack.Children.Add(Label("Mermaid 图表源码 · 原生预览暂不执行图表脚本", 11, Fnt));
                    stack.Children.Add(new TextBlock { Text = block.Text, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, Foreground = Brush(Txt) });
                    panel.Children.Add(new Border { Child = stack, Padding = new Thickness(14), Background = Brush(Hex(0xF6F6F3)), CornerRadius = new CornerRadius(8) });
                    break;
                }
                case "table":
                {
                    var grid = new Grid { ColumnSpacing = 16, RowSpacing = 10 };
                    var columns = block.Rows.Max(r => r.Count);
                    for (var c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    for (var r = 0; r < block.Rows.Count; r++)
                    {
                        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                        for (var c = 0; c < block.Rows[r].Count; c++)
                        {
                            var cell = Inline(block.Rows[r][c], 12, r == 0 ? Semibold : Regular);
                            cell.MinWidth = 80;
                            cell.MaxWidth = 280;
                            Grid.SetRow(cell, r);
                            Grid.SetColumn(cell, c);
                            grid.Children.Add(cell);
                        }
                    }
                    var frame = new Border { Child = grid, Padding = new Thickness(12), CornerRadius = new CornerRadius(8), BorderBrush = Brush(Hex(0xE4E4E0)), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left };
                    panel.Children.Add(new ScrollViewer { Content = frame, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Disabled });
                    break;
                }
                case "image":
                    panel.Children.Add(HStack(6, Icon("photo", 12, Fnt), Label("文档图片请下载原文件查看", 12, Fnt)));
                    break;
                default:
                {
                    var text = Inline(block.Text, size, Regular);
                    text.LineHeight(line > 0 ? line : size * 1.2);
                    panel.Children.Add(text);
                    break;
                }
            }
        }
        return panel;
    }

    /// <summary>
    /// 行内 Markdown（Swift `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)`）：**粗体**、*斜体*、`代码`、~~删除线~~、[链接](地址)。
    /// 链接只显示文字（与 Mac 相同，不在预览里打开网络地址）。
    /// </summary>
    public static TextBlock Inline(string source, double size, Windows.UI.Text.FontWeight weight)
    {
        var block = new TextBlock { FontSize = size, FontFamily = SansFamily, FontWeight = weight, Foreground = Brush(Txt), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        foreach (var chunk in Regex.Split(source, @"(\*\*[^*]+\*\*|~~[^~]+~~|`[^`]+`|\[[^\]]+\]\([^)]+\)|(?<![*\w])\*[^*\s][^*]*\*(?!\*))"))
        {
            if (chunk.Length == 0) continue;
            var run = new Run { Text = chunk };
            if (chunk.StartsWith("**", StringComparison.Ordinal) && chunk.EndsWith("**", StringComparison.Ordinal) && chunk.Length > 4) { run.Text = chunk[2..^2]; run.FontWeight = Semibold; }
            else if (chunk.StartsWith("~~", StringComparison.Ordinal) && chunk.EndsWith("~~", StringComparison.Ordinal) && chunk.Length > 4) { run.Text = chunk[2..^2]; run.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough; }
            else if (chunk.StartsWith('`') && chunk.EndsWith('`') && chunk.Length > 2) { run.Text = chunk[1..^1]; run.FontFamily = new FontFamily("Cascadia Mono, Consolas"); }
            else if (chunk.StartsWith('[') && Regex.Match(chunk, @"^\[([^\]]+)\]\(") is { Success: true } link) { run.Text = link.Groups[1].Value; run.Foreground = Brush(Link); }
            else if (chunk.StartsWith('*') && chunk.EndsWith('*') && chunk.Length > 2) { run.Text = chunk[1..^1]; run.FontStyle = Windows.UI.Text.FontStyle.Italic; }
            block.Inlines.Add(run);
        }
        return block;
    }
}
