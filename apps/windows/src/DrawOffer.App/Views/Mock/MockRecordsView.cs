using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Mock.MockReportData;

namespace DrawOffer.App.Views.Mock;

/// <summary>Mac MockRecordsV2: completed rows, with abandoned sessions folded below.</summary>
public sealed class MockRecordsView : UserControl
{
    readonly Action _home; readonly Action<string> _open;
    MockViewLifetime? _life;
    List<JsonNode>? _items;
    readonly Dictionary<string,string> _headlines = [];
    string? _error; string? _notice;
    bool _abandoned, _busy;
    V3Overlay? _dialog;
    readonly StackPanel _body = new();
    public MockRecordsView(Action home, Action<string> open)
    {
        (_home, _open) = (home, open); Background = Brush(White); Content = new V3Page(_body);
        Loaded += (_, _) => { _life = new(this, ClearPrivate); Render(); _ = Load(); };
        Unloaded += (_, _) => _dialog?.Close();
    }
    void ClearPrivate() { _dialog?.Close(); _items = null; _headlines.Clear(); _notice = null; _error = "登录状态已变化，请返回模拟面试。"; Render(); }
    async Task Load()
    {
        if (_life is null || !_life.Alive) return;
        _error = null; Render();
        try
        {
            if (App.Session.User is null) { _items = []; Render(); return; }
            var items = new List<JsonNode>(); var cursors = new HashSet<string>(); var cursor = "";
            do
            {
                var query = new Dictionary<string,string> { ["limit"] = "100" }; if (cursor.Length > 0) query["cursor"] = cursor;
                var page = await _life.Request("/api/mock-interviews", query: query); items.AddRange(page.Items("items")); cursor = page.Text("next_cursor");
                if (cursor.Length > 0 && !cursors.Add(cursor)) throw new InvalidDataException("重复的分页游标");
            } while (cursor.Length > 0);
            _items = items; Render();
            foreach (var item in items.Where(i => i.Text("status") == "completed").OrderByDescending(When).Take(24))
            {
                try { var detail = await _life.Request("/api/mock-interviews/" + item.Display("id")); _headlines[item.Display("id")] = detail.Get("mock_interview").Get("report").Text("headline"); Render(); }
                catch (OperationCanceledException) { return; } catch { /* A missing headline must not hide a record. */ }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (_life.Alive) { _error = Error(e); Render(); } }
    }
    void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(Spread(HStack(12, LinkButton("← 模拟面试", _home), Sans("/", 16, Fnt), Sans("练习记录", 16, Fnt)), new V3Button("练一场新的", _home, V3Button.Kind.Dark)));
        _body.Children.Add(Serif("练习记录", 30).Top(12));
        var sorted = (_items ?? []).OrderByDescending(When).ToList(); var completed = sorted.Where(i => i.Text("status") == "completed").ToList(); var abandoned = sorted.Where(i => i.Text("status") == "abandoned").ToList();
        var summary = string.Join(" · ", new[] { completed.Count > 0 ? $"完成 {completed.Count} 场" : null, abandoned.Count > 0 ? $"另有 {abandoned.Count} 场中途放弃" : null }.OfType<string>());
        if (summary.Length > 0) _body.Children.Add(Sans(summary, 14, Sub).Top(6));
        if (_notice is not null) _body.Children.Add(Paragraph(_notice, 12, Red).Top(12));
        if (_error is not null)
            _body.Children.Add(VStack(10, Serif(_items is null ? "练习记录没有加载出来" : "刷新记录失败", 18), Paragraph(_error), new V3Button("重新加载", () => _ = Load())).Top(_items is null ? 160 : 20));
        else if (_items is null) _body.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24, Margin = new Thickness(0, 120, 0, 0) });
        else if (completed.Count == 0 && abandoned.Count == 0) _body.Children.Add(VStack(10, Serif("还没有练习", 18), Sans("练完一场，这里会多一行记录，点开就是这场的报告。", 13.5, Fnt)).Top(160));
        if (_items is null) return;
        var list = new StackPanel { Margin = new Thickness(0, 36, 0, 0) };
        if (completed.Count > 0) list.Children.Add(Sans($"完成的 {completed.Count} 场", 15, Txt, Medium).Pad(0, 0, 0, 12));
        foreach (var item in completed) list.Children.Add(Record(item, false));
        if (abandoned.Count > 0)
        {
            list.Children.Add(Divider());
            list.Children.Add(Tap(Spread(Sans(completed.Count == 0 ? $"{abandoned.Count} 场都在开始后放弃，没有报告" : $"另有 {abandoned.Count} 场开始后放弃，没有报告", 13.5, Fnt), Sans(_abandoned ? "收起 ⌃" : "展开 ⌄", 13.5, Fnt)).Frame(height: 56), () => { _abandoned = !_abandoned; Render(); }, "展开或收起放弃的练习"));
            if (_abandoned) foreach (var item in abandoned) list.Children.Add(Record(item, true));
        }
        _body.Children.Add(list);
    }
    UIElement Record(JsonNode item, bool off)
    {
        var id = item.Display("id"); var date = Json.Date(When(item))?.ToBeijing(); var week = new[] { "周日", "周一", "周二", "周三", "周四", "周五", "周六" };
        var copy = VStack(6, HStack(12, Sans(Job(item), 15, off ? Sub : Txt, off ? Regular : Medium), Sans(Settings(item), 13, Fnt)), _headlines.GetValueOrDefault(id) is { Length: > 0 } headline ? Sans(headline, 13.5, Sub) : null);
        var tone = Tone(item.Text("verdict"));
        var actions = HStack(8);
        if (off) actions.Children.Add(new V3Button("用同样设置重来 ›", () => _ = Repeat(id), V3Button.Kind.Text) { Enabled = !_busy });
        else actions.Children.Add(LinkButton("看报告 ›", () => _open(id)));
        V3Button? menu = null; menu = new V3Button("···", () =>
        {
            var popup = new MenuFlyout();
            var repeat = new MenuFlyoutItem { Text = "用同样设置重来", IsEnabled = !_busy }; repeat.Click += (_, _) => _ = Repeat(id); popup.Items.Add(repeat);
            var delete = new MenuFlyoutItem { Text = "删除记录", IsEnabled = !_busy }; delete.Click += (_, _) => Delete(item); popup.Items.Add(delete); popup.ShowAt(menu!);
        }, V3Button.Kind.Text).Tip("练习记录菜单"); actions.Children.Add(menu);
        var dateCell = VStack(2, Label(date?.ToString("MM·dd") ?? "—", 15, off ? Fnt : Txt, Medium), Sans(date is {} d ? week[(int)d.DayOfWeek] : "—", 12, Fnt));
        var row = Columns(16, (Px(64), dateCell), (Star(), off ? copy : Tap(copy, () => _open(id), "查看" + Job(item) + "的报告")),
            (Px(off ? 0 : 56), off ? new Border() : Number(item.Number("total_score")?.ToString("F0") ?? "—", 26, tone)),
            (Px(off ? 0 : 76), off ? new Border() : Sans(Verdict(item.Text("verdict")), 12.5, tone)), (Auto, actions));
        row.Padding = new Thickness(0, 14, 0, 14); row.MinHeight = off ? 60 : 76;
        return VStack(0, Divider(), row);
    }
    async Task Repeat(string id)
    {
        if (_busy || _life is null) return; _busy = true; _notice = null; Render();
        try { var value = await _life.Request($"/api/mock-interviews/{id}/repeat", "POST"); var next = value.Get("mock_interview").Display("id"); if (next.Length == 0) throw new InvalidDataException(); _open(next); }
        catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) _notice = "没有开始新的一场 · " + Error(e); }
        finally { _busy = false; if (_life.Alive) Render(); }
    }
    void Delete(JsonNode item)
    {
        if (_busy || XamlRoot is null) return;
        _dialog = V3Overlay.Show(XamlRoot, close => V3Dialog.Make(VStack(12, V3DialogHead.Make("删除练习记录？"), Paragraph("永久删除本场练习、报告及录音，无法恢复。")), [new V3Button("取消", close), new V3Button("删除记录", () => { close(); _ = Remove(item.Display("id")); }, V3Button.Kind.Danger)], close));
    }
    async Task Remove(string id)
    {
        if (_life is null || _busy) return; _busy = true; Render();
        try { await _life.Request("/api/mock-interviews/" + id, "DELETE"); _items?.RemoveAll(i => i.Display("id") == id); _headlines.Remove(id); }
        catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) _notice = "记录没有删除 · " + Error(e); }
        finally { _busy = false; if (_life.Alive) Render(); }
    }
}
