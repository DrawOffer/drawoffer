using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 全部记录（Windows 稿 09 · 08.01 列表、08.02 空状态、08.03 展开放弃的场次；Mac `MockRecordsV2`、Web `v2/RecordsPage.tsx`）：
/// 模拟和真实面试放在一张表里，每一场卡在哪都能看到；开始后放弃的场次合成最后一行，展开后可以用同样设置重来。
/// </summary>
internal sealed class MockRecordsView : UserControl
{
    readonly Action _back, _startFirst;
    readonly Action<string> _openReport, _open;
    readonly Action<string, string?> _openReal;
    readonly MockViewLifetime _life;
    readonly StackPanel _page = new();
    JsonNode? _overview;
    bool _failed, _unfolded;

    public MockRecordsView(Action back, Action<string> openReport, Action<string> open, Action<string, string?> openReal, Action startFirst)
    {
        (_back, _openReport, _open, _openReal, _startFirst) = (back, openReport, open, openReal, startFirst);
        _life = new MockViewLifetime(this, back);
        Background = Brush(V3.White);
        Content = new V3Page(_page, 40);
        Render();
        Loaded += (_, _) => _ = Load();
    }

    async Task Load()
    {
        try { _overview = await _life.Request("/api/mock-interviews/overview"); _failed = false; }
        catch (OperationCanceledException) { return; }
        catch { _failed = true; }
        if (_life.Alive) Render();
    }

    static string Mmdd(string value) => Json.Date(value)?.ToBeijing().ToString("MM-dd") ?? "";

    void Render()
    {
        _page.Children.Clear();
        var records = _overview.Items("records");
        var rows = records.Where(r => r.Text("status") != "abandoned").ToList();
        var abandoned = records.Where(r => r.Text("status") == "abandoned").ToList();
        var empty = _overview is not null && rows.Count == 0 && abandoned.Count == 0;

        _page.Children.Add(HStack(6, Icon("arrow.left", 13, MP.Fnt), Sans("模拟面试", 16, MP.Fnt)).OnTap(_back, "返回模拟面试").Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
        var heading = VStack(0,
            Serif(_overview is null ? "全部记录" : Heading(rows, _overview.Get("tallies").Get("score")), 28, MP.Ink).LineHeight(36).Wrap(),
            Sans("每一场卡在哪，都在这里。", 14, MP.Sub).Frame(height: 22).Top(8));
        var import = MP.Ghost("导入面试记录", Import, 38);
        import.VerticalAlignment = VerticalAlignment.Bottom;
        _page.Children.Add(Columns(24, (Star(), heading), (Auto, import)).Top(20));

        if (_overview is null && !_failed) { _page.Children.Add(new V3Loading("正在加载练习记录…").Top(120)); return; }
        if (empty) { _page.Children.Add(EmptyState().Top(40)); return; }

        var table = new StackPanel { Margin = new Thickness(0, 40, 0, 0) };
        var head = Cells(26, Sans("时间", 12.5, MP.Fnt), Sans("面试", 12.5, MP.Fnt), Sans("卡在", 12.5, MP.Fnt), Sans("分数", 12.5, MP.Fnt).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Right; t.Margin = new Thickness(0, 0, 54, 0); }));
        table.Children.Add(new Border { Child = head, BorderBrush = Brush(MP.Cl), BorderThickness = new Thickness(0, 0, 0, 1) });
        if (_failed && _overview is null)
            table.Children.Add(HStack(8, Sans("记录没有加载出来。", 13, MP.Fnt), MP.Link("重新加载", () => _ = Load(), blue: true)).Top(20));
        foreach (var item in rows) table.Children.Add(Row(item));
        if (abandoned.Count > 0)
            table.Children.Add(MP.Link(_unfolded ? "收起" : $"另有 {abandoned.Count} 场开始后放弃 · 展开", () => { _unfolded = !_unfolded; Render(); })
                .Also(t => { t.Height = 46; t.Padding = new Thickness(0, 14, 0, 0); }));
        if (_unfolded)
            foreach (var item in abandoned)
            {
                var info = VStack(2, Sans(item.Text("title"), 14, MP.Fnt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis), Sans(item.Text("subtitle"), 13, MP.Mute).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
                var grid = Cells(64, Sans(Mmdd(item.Text("at")), 13.5, MP.Mute), info, new Border(),
                    MP.Link("用同样设置重来 ›", () => _ = Repeat(item.Text("id")), blue: true).Also(t => t.HorizontalAlignment = HorizontalAlignment.Right));
                table.Children.Add(new Border { Child = grid, BorderBrush = Brush(MP.Line), BorderThickness = new Thickness(0, 0, 0, 1) });
            }
        _page.Children.Add(table);
    }

    /// <summary>表格四列：时间 11.6%、面试 34.2%、卡在、分数（右对齐）；列位置按 860 宽设计稿换成比例。</summary>
    static Grid Cells(double height, params FrameworkElement[] cells)
    {
        var grid = new Grid { Height = height, ColumnSpacing = 0 };
        foreach (var w in new[] { 11.63, 34.18, 41.86, 12.33 }) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w, GridUnitType.Star) });
        for (var i = 0; i < cells.Length; i++)
        {
            cells[i].VerticalAlignment = VerticalAlignment.Center;
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(cells[i], i);
            grid.Children.Add(cells[i]);
        }
        return grid;
    }

    /// <summary>`.mi3-rec`：72 高的一行；悬停只换浅底。</summary>
    FrameworkElement Row(JsonNode item)
    {
        var reviewing = item.Text("status") == "reviewing";
        var info = VStack(1,
            Label(item.Text("title"), 14, MP.Ink, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Frame(height: 22),
            Sans(item.Text("subtitle"), 13, MP.Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Frame(height: 20));
        info.Margin = new Thickness(0, 0, 24, 0);
        FrameworkElement stuck = new Border();
        if (item.Get("stuck") is JsonObject s)
            stuck = Columns(8,
                (Auto, new Ellipse { Width = 6, Height = 6, Fill = Brush(MP.Orange), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 0, 0) }),
                (Star(), VStack(1,
                    Label(s.Text("topic"), 14, MP.Ink, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Frame(height: 22),
                    Sans(s.Text("detail"), 13, MP.Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Frame(height: 20))));
        var score = item.Number("score") is { } value
            ? (FrameworkElement)Serif(((int)value).ToString(), 22, MP.Ink)
            : Sans(reviewing ? "复盘中" : "—", 13, MP.Mute);
        var arrow = Sans("›", 16, MP.Mute).Also(t => { t.Width = 50; t.TextAlignment = TextAlignment.Right; t.Opacity = reviewing ? 0 : 1; });
        var right = HStack(0, score.Align(v: VerticalAlignment.Center), arrow.Align(v: VerticalAlignment.Center).Pad(0, 0, 4, 0));
        right.HorizontalAlignment = HorizontalAlignment.Right;
        var grid = Cells(72, Label(Mmdd(item.Text("at")), 14, MP.Ink, Medium), info, stuck, right);
        var row = new Border { Child = grid, Background = Brush(Clear), BorderBrush = Brush(MP.Line), BorderThickness = new Thickness(0, 0, 0, 1) };
        if (!reviewing) row.OnHover(h => row.Background = Brush(h ? MP.RowHover : Clear));
        return row.OnTap(() => Tap(item), item.Text("title"));
    }

    /// <summary>空列表（Windows 稿 09 · 08.02）：一张空的记录表，三行等着填。</summary>
    FrameworkElement EmptyState()
    {
        var art = new Canvas { Width = 132, Height = 92 };
        art.Children.Add(new Rectangle { Width = 132, Height = 92, RadiusX = 6, RadiusY = 6, Fill = Brush(V3.White), Stroke = Brush(MP.Cl), StrokeThickness = 1 });
        var bar = new Rectangle { Width = 36, Height = 4, RadiusX = 2, RadiusY = 2, Fill = Brush(MP.Ink) };
        Canvas.SetLeft(bar, 12); Canvas.SetTop(bar, 12); art.Children.Add(bar);
        foreach (var y in new[] { 28.0, 48, 68 })
        {
            var line = new Rectangle { Width = 106, Height = 13, RadiusX = 3, RadiusY = 3, Stroke = Brush(MP.Cl), StrokeThickness = 1, StrokeDashArray = [3, 2] };
            Canvas.SetLeft(line, 12); Canvas.SetTop(line, y); art.Children.Add(line);
        }
        var card = V3EmptyCard.Make("还没有面试记录", "练完一场模拟面试，这里就会多一行。\n面过的真实面试，可以用右上角「导入面试记录」补进来。", art,
            [MP.Dark("开始第一场模拟面试", _startFirst, 34)], stageHeight: 160);
        card.HorizontalAlignment = HorizontalAlignment.Left;
        return card;
    }

    static string Heading(List<JsonNode> rows, JsonNode? score)
    {
        if (rows.Count == 0) return "全部记录";
        if (score is JsonObject && score.Integer("count") >= 2) return $"{rows.Count} 场面试，从 {score.Integer("first")} 分到 {score.Integer("latest")} 分。";
        return $"{rows.Count} 场面试。";
    }

    void Tap(JsonNode item)
    {
        // 复盘还没生成，详情页没有可看的内容，留在列表里提示
        if (item.Text("status") == "reviewing") { MP.Notice("复盘还在生成", "好了这一行会显示分数，到时再点开看"); return; }
        if (item.Text("kind") == "mock") _openReport(item.Text("id"));
        else _openReal(item.Text("id"), item.Text("application_id").NonEmpty());
    }

    void Import()
    {
        if (XamlRoot is null) return;
        MockImportDialog.Show(XamlRoot, () => { MP.Notice("已开始生成复盘", "好了会出现在这里，也会记进长期记忆"); _ = Load(); });
    }

    async Task Repeat(string id)
    {
        try { _open((await _life.Request($"/api/mock-interviews/{id}/repeat", "POST")).Get("mock_interview").Display("id")); }
        catch (OperationCanceledException) { }
        catch (Exception error) { MP.Notice("没有开始新的一场", MP.Error(error), error: true); }
    }
}
