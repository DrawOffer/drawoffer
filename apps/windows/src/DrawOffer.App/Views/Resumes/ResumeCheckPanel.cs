using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using S = DrawOffer.App.Views.Resumes.EditorJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>检查结果留在编辑器里：收起面板不丢，纸面上沿按它显示“检查 · 剩 N 处”。</summary>
public sealed class ResumeCheckState
{
    public enum Step { Idle, Reading, List, Item, Failed }
    public Step Phase { get; set; } = Step.Idle;
    /// <summary>Phase 为 Item 时正在看第几处。</summary>
    public int Index { get; set; }
    /// <summary>Phase 为 Failed 时是不是积分不够。</summary>
    public bool Credit { get; set; }
    public List<ResumeCheck.Unit> Units { get; set; } = [];
    public string Summary { get; set; } = "";
    public string Basis { get; set; } = "";
    public List<ResumeCheck.Finding> Findings { get; set; } = [];

    /// <summary>还剩几处没处理；没在检查（没读、正在读、失败）时为 null。</summary>
    public int? Remaining => Phase is Step.List or Step.Item ? Findings.Count(x => x.Status == ResumeCheck.Status.Open) : null;

    public void Reset() { Phase = Step.Idle; Index = 0; Credit = false; Units = []; Summary = ""; Basis = ""; Findings = []; }
}

/// <summary>
/// 检查简历（Figma 分区 12.7–12.11「检查简历：对话版」，Mac `ResumeCheckPanel.swift`）：纸面上沿右边「检查简历」打开，
/// 摆在纸的右边、不加卡片，和修改对话同一种写法。职绘读完整份先说一句结论，再一处一处带着改：
/// 能直接改的放出改好的一句（补出来的说法标橙），缺事实的一次只问一件事，可以删的删掉或并进另一条，整段换这一段的标题。
/// 收起后结果保留，上沿入口显示还剩几处；下次打开接着看，点「再检查一遍」才重读。
/// </summary>
public sealed class ResumeCheckPanel : UserControl
{
    readonly string _resumeId;
    readonly Func<JsonNode?> _document;
    readonly Func<JsonNode, string> _label;
    readonly Func<int> _pageCount;
    readonly ResumeCheckState _state;
    readonly Action<JsonNode> _write;
    readonly Action _changed;
    readonly Action _close;

    bool _busy;
    string? _notice;
    CancellationTokenSource? _task;
    /// <summary>用户上一句（点的快捷回答或打的字），显示成右侧灰底小气泡。</summary>
    string? _said;

    /// <param name="changed">检查状态变了（编辑器据此更新上沿入口、纸边圆圈和预览）。</param>
    public ResumeCheckPanel(string resumeId, Func<JsonNode?> document, Func<JsonNode, string> label, Func<int> pageCount, ResumeCheckState state,
        Action<JsonNode> write, Action changed, Action close)
    {
        _resumeId = resumeId;
        _document = document;
        _label = label;
        _pageCount = pageCount;
        _state = state;
        _write = write;
        _changed = changed;
        _close = close;
        Width = ResumeTalk.ColumnWidth;
        Render();
        var started = false;
        Loaded += (_, _) => { if (started) return; started = true; if (_state.Phase == ResumeCheckState.Step.Idle) Read(); };
        Unloaded += (_, _) => { if (_state.Phase == ResumeCheckState.Step.Reading) { _task?.Cancel(); _state.Reset(); _changed(); } };
    }

    /// <summary>纸面正文变了：这一行的文字变了就算处理过（Web：改过的那一行圆圈自动消失）。</summary>
    public void DocumentChanged() { if (Settle(_document())) { Render(); _changed(); } }

    /// <summary>纸边圆圈点开某一处。</summary>
    public void Go(int index) { Go(index, null); }

    void Render()
    {
        var items = new List<UIElement?>();
        switch (_state.Phase)
        {
            case ResumeCheckState.Step.Idle or ResumeCheckState.Step.Reading:
                items.Add(ResumeTalk.Assistant("正在读这份简历", "一次读完，十几秒。", thinking: true));
                items.Add(ResumeTalk.Chips([("停止", () => { _task?.Cancel(); _state.Reset(); _changed(); _close(); })]));
                break;
            case ResumeCheckState.Step.Failed:
                items.Add(ResumeTalk.Assistant(_state.Credit ? "积分不够了，这次没读完。" : "这次没读完。",
                    _state.Credit ? "简历没有改动。在左下角账户里充值后点重试。" : "没连上或出错了，简历没有改动。"));
                items.Add(ResumeTalk.Chips([("重试", Read), ("先收起", () => { _state.Reset(); _changed(); _close(); })]));
                break;
            case ResumeCheckState.Step.Item when _state.Index >= 0 && _state.Index < _state.Findings.Count:
                Item(items, _state.Findings[_state.Index], _state.Index);
                break;
            default:
                List(items);
                break;
        }
        Content = ResumeTalk.Column([.. items]);
    }

    /// <summary>12.7 读完先说结论；12.11 都看过了交回正常编辑。</summary>
    void List(List<UIElement?> items)
    {
        var findings = _state.Findings;
        var open = findings.Count(x => x.Status == ResumeCheck.Status.Open);
        var firstOpen = findings.FindIndex(x => x.Status == ResumeCheck.Status.Open);
        var handled = findings.Count - open;
        string text;
        string? note;
        if (findings.Count == 0)
        {
            text = _state.Units.Count == 0 ? "先写几条经历再来检查。" : "读完了，没发现要改的地方。";
            note = _state.Summary.Length == 0 ? null : _state.Summary;
        }
        else if (open == 0)
        {
            var applied = findings.Count(x => x.Status == ResumeCheck.Status.Applied);
            text = $"{findings.Count} 处都看完了" + (applied == findings.Count ? "，全部换上了。" : "。");
            note = "改动都能撤销。想再看一遍，点纸面上沿的“检查简历”。";
        }
        else
        {
            text = handled > 0 ? $"还有 {open} 处值得改。" : $"读完了。有 {open} 处值得改。";
            var joined = (_state.Basis.Length == 0 ? "" : $"按{_state.Basis}的眼光看的：") + _state.Summary;
            note = joined.Length == 0 ? null : joined;
        }
        if (_said is { } said) items.Add(ResumeTalk.User(said, faded: true));
        UIElement? rows = null;
        if (findings.Count > 0 && open > 0)
        {
            var stack = VStack(0, findings.Select((finding, position) => (UIElement?)Row(finding, position)).ToArray());
            stack.Margin = new Thickness(0, 12, 0, 0);
            rows = stack;
        }
        items.Add(ResumeTalk.Assistant(text, note, extra: rows));
        if (firstOpen >= 0)
            items.Add(ResumeTalk.Chips([($"从第 {firstOpen + 1} 处开始", () => Go(firstOpen, $"从第 {firstOpen + 1} 处开始")), ("先不改，我自己看", _close)]));
        else
            items.Add(ResumeTalk.Chips([("好了", _close), ("再检查一遍", Read)]));
    }

    /// <summary>结论下面的几处：编号 + 一句话 + 位置；处理过的划掉。点一行直接看那一处。</summary>
    FrameworkElement Row(ResumeCheck.Finding finding, int position)
    {
        var done = finding.Status != ResumeCheck.Status.Open;
        var label = Sans(finding.Label, 13, done ? Fnt2 : Txt);
        if (done) label.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
        var texts = VStack(2, label, Sans(finding.Where, 11.5, ResumeTalk.Note));
        var number = Number($"{position + 1}", 12, ResumeTalk.Note, Medium).Frame(width: 14);
        number.VerticalAlignment = VerticalAlignment.Top;
        number.Margin = new Thickness(0, 1, 0, 0);
        UIElement status = done ? Sans(finding.Status == ResumeCheck.Status.Applied ? "已换上" : "不改", 11.5, ResumeTalk.Note).Align(v: VerticalAlignment.Top) : new Border();
        var row = Columns(8, (GridLength.Auto, number), (Star(), texts), (GridLength.Auto, status));
        row.Padding = new Thickness(0, 6, 0, 6);
        row.Background = Brush(Clear);
        row.OnTap(() => Go(position, $"看第 {position + 1} 处"), $"看第 {position + 1} 处：{finding.Label}", () => !done);
        return row;
    }

    /// <summary>12.8 改写 / 12.9 补全 / 12.10 整段：职绘说第几处、为什么，改好的一句放在纸上；快捷回答 + 一行输入。</summary>
    void Item(List<UIElement?> items, ResumeCheck.Finding finding, int index)
    {
        var lead = $"第 {index + 1} 处：{finding.Title}" + (finding.Detail.Length == 0 ? "" : (finding.Title.EndsWith('。') ? "" : "。") + finding.Detail);
        if (_said is { } said) items.Add(ResumeTalk.User(said, faded: _busy));
        if (finding.Fix is "delete" or "merge")
        {
            items.Add(ResumeTalk.Assistant(lead));
            items.Add(ResumeTalk.Chips(RemoveChips(finding), _busy));
            items.Add(ResumeTalk.Notice(_notice));
            return;
        }
        // 12.8：改好的一句直接显示在纸上那一行，对话里不再贴一遍；整段换标题时纸上没有对应的行，标题建议写在这里
        UIElement? extra = null;
        if (finding.Suggestion is { } suggestion && finding.Fix == "entry")
        {
            var stack = VStack(0);
            if (finding.Caption.Length > 0) stack.Children.Add(Sans(finding.Caption, 12, ResumeTalk.Note).Wrap().Top(10));
            stack.Children.Add(ResumeTalk.Proposal(suggestion, finding.Risky));
            extra = stack;
        }
        items.Add(ResumeTalk.Assistant(lead, ItemNote(finding), thinking: _busy, extra: extra));
        if (finding.Suggestion is not null)
            items.Add(ResumeTalk.Chips([("换上，看下一处", () => Apply(finding)), ("这处不用改", () => Mark(ResumeCheck.Status.Skipped, said: "这处不用改"))], _busy));
        else
            items.Add(ResumeTalk.Chips([("跳过这处", () => Mark(ResumeCheck.Status.Skipped, said: "跳过这处"))], _busy));
        items.Add(ResumeTalk.Notice(_notice));
        items.Add(ResumeTalk.Input(Placeholder(finding), text => Send(finding, text), _busy));
    }

    List<(string, Action)> RemoveChips(ResumeCheck.Finding finding)
    {
        var chips = new List<(string, Action)> { ("删掉这一条", () => Remove(finding, merge: false)) };
        if (finding.Fix == "merge" && finding.MergeInto is not null && finding.Suggestion is not null) chips.Add((MergeLabel(finding), () => Remove(finding, merge: true)));
        chips.Add(("留着，不用改", () => Mark(ResumeCheck.Status.Skipped, said: "留着，不用改")));
        return chips;
    }

    string? ItemNote(ResumeCheck.Finding finding)
    {
        if (_busy) return finding.Fix == "entry" ? "正在重看这一段…" : "正在重写这一句…";
        if (finding.Risky.Count > 0) return $"橙色 {finding.Risky.Count} 处是按这类工作的常见水平补的，换上前改成你的真实情况，面试会被追问。";
        if (finding.Fix == "entry" && finding.Ask.Length > 0) return finding.Ask;
        if (finding.Suggestion is null) return finding.Example.Length == 0 ? "写大白话就行，我来整理。" : $"比如：{finding.Example}";
        return null;
    }

    static string Placeholder(ResumeCheck.Finding finding)
    {
        if (finding.Suggestion is null || finding.Fix == "entry") return "或者直接打字回答";
        return finding.Risky.Count == 0 ? "或者说说哪里不对，我重写" : "或者说说真实情况，我重写";
    }

    string MergeLabel(ResumeCheck.Finding finding)
    {
        var unit = _state.Units.FirstOrDefault(x => x.Id == finding.EntryId);
        var at = unit?.Lines.ToList().FindIndex(x => x.Id == finding.LineId) ?? -1;
        if (unit is null || at <= 0) return "并进那一条";
        return unit.Lines[at - 1].Id == finding.MergeInto ? "并进上一条" : "并进那一条";
    }

    // MARK: Actions

    void Read()
    {
        _task?.Cancel();
        var units = ResumeCheck.Units(_document(), _label);
        _state.Reset();
        _state.Phase = ResumeCheckState.Step.Reading;
        _state.Units = units;
        _notice = null; _said = null;
        if (units.Count == 0)
        {
            _state.Phase = ResumeCheckState.Step.List;
            _state.Summary = "先写几条经历再来检查。";
            Render(); _changed();
            return;
        }
        Render(); _changed();
        var cancel = new CancellationTokenSource();
        _task = cancel;
        _ = Run();
        async Task Run()
        {
            try
            {
                var response = await App.Session.Api.CareerRequestAsync($"/api/resumes/{_resumeId}/review:check", "POST", body: ResumeCheck.CheckBody(units, _pageCount()));
                if (cancel.IsCancellationRequested) return;
                var result = ResumeCheck.ResultOf(response, units);
                _state.Phase = ResumeCheckState.Step.List;
                _state.Summary = result.Summary;
                _state.Basis = result.Basis;
                _state.Findings = result.Findings.ToList();
            }
            catch (Exception error)
            {
                if (cancel.IsCancellationRequested) return;
                if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
                _state.Phase = ResumeCheckState.Step.Failed;
                _state.Credit = ResumeCheck.ErrorMessage(error).Credit;
            }
            Render(); _changed();
        }
    }

    void Go(int index, string? said)
    {
        _notice = null; _said = said;
        _state.Phase = ResumeCheckState.Step.Item;
        _state.Index = index;
        Render(); _changed();
    }

    /// <summary>结算一处，并按纸面现状把被顺带改掉的处标成已换上，然后去下一处。</summary>
    void Mark(ResumeCheck.Status status, JsonNode? next = null, string? said = null)
    {
        if (_state.Phase != ResumeCheckState.Step.Item) return;
        var index = _state.Index;
        _said = said;
        _state.Findings[index].Status = status;
        Settle(next ?? _document());
        _notice = null;
        var findings = _state.Findings;
        var following = Enumerable.Range(0, findings.Count).Where(i => i > index && findings[i].Status == ResumeCheck.Status.Open)
            .Concat(Enumerable.Range(0, findings.Count).Where(i => findings[i].Status == ResumeCheck.Status.Open)).Select(i => (int?)i).FirstOrDefault();
        if (following is { } i) { _state.Phase = ResumeCheckState.Step.Item; _state.Index = i; }
        else _state.Phase = ResumeCheckState.Step.List;
        Render(); _changed();
    }

    /// <summary>纸面上这一行的文字变了就算处理过。返回是否有变化。</summary>
    bool Settle(JsonNode? next)
    {
        var changed = false;
        foreach (var finding in _state.Findings.Where(x => x.Status == ResumeCheck.Status.Open && x.LineId is not null))
        {
            var text = ResumeCheck.LineText(next, finding.LineId!);
            if (text?.Trim() != finding.Before.Trim()) { finding.Status = ResumeCheck.Status.Applied; changed = true; }
        }
        return changed;
    }

    void FailedWrite(ResumeCheck.WriteError error)
    {
        _notice = error == ResumeCheck.WriteError.Conflict ? "这一处刚被改过，没换上。" : "纸面上找不到这一处了。";
        Render();
    }

    void Apply(ResumeCheck.Finding finding)
    {
        if (finding.Suggestion is not { } suggestion) return;
        (JsonNode? Document, ResumeCheck.WriteError Error) result;
        if (finding.Fix == "entry")
        {
            if (_state.Units.FirstOrDefault(x => x.Id == finding.EntryId)?.HeadingField is not { } field) { FailedWrite(ResumeCheck.WriteError.Missing); return; }
            result = ResumeCheck.ReplaceHeading(_document(), finding.EntryId, field, finding.Before, suggestion);
        }
        else
        {
            if (finding.LineId is not { } lineId) return;
            result = ResumeCheck.ReplaceLine(_document(), lineId, finding.Before, suggestion);
        }
        if (result.Error != ResumeCheck.WriteError.None || result.Document is not { } next) { FailedWrite(result.Error == ResumeCheck.WriteError.None ? ResumeCheck.WriteError.Missing : result.Error); return; }
        Mark(ResumeCheck.Status.Applied, next, "换上，看下一处");
        _write(next);
    }

    /// <summary>17.5：删掉这一条；并进另一条时先把另一条换成并好的那句，再删这一条。</summary>
    void Remove(ResumeCheck.Finding finding, bool merge)
    {
        if (finding.LineId is not { } lineId) return;
        var label = merge ? MergeLabel(finding) : "删掉这一条";
        var basis = _document();
        if (merge && finding.MergeInto is { } target && finding.Suggestion is { } suggestion)
        {
            var merged = ResumeCheck.ReplaceLine(basis, target, finding.MergeBefore, suggestion);
            if (merged.Error != ResumeCheck.WriteError.None || merged.Document is null) { FailedWrite(merged.Error); return; }
            basis = merged.Document;
        }
        var removed = ResumeCheck.DeleteLine(basis, lineId, finding.Before);
        if (removed.Error != ResumeCheck.WriteError.None || removed.Document is not { } next) { FailedWrite(removed.Error); return; }
        Mark(ResumeCheck.Status.Applied, next, label);
        _write(next);
    }

    void Send(ResumeCheck.Finding finding, string text)
    {
        text = text.Trim();
        if (text.Length == 0 || _busy) return;
        _said = text;
        _ = Revise(finding, text);
    }

    /// <summary>用户说了一句：整段带着这句只重看这一段；一条按这句重写（基于当前建议）。</summary>
    async Task Revise(ResumeCheck.Finding finding, string instruction)
    {
        if (_state.Units.FirstOrDefault(x => x.Id == finding.EntryId) is not { } unit) return;
        _busy = true; _notice = null;
        Render();
        try
        {
            if (finding.Fix == "entry" || finding.LineId is null)
            {
                var response = await App.Session.Api.CareerRequestAsync($"/api/resumes/{_resumeId}/review:check", "POST",
                    body: ResumeCheck.CheckBody([unit], _pageCount(), (unit.Id, instruction)));
                var next = S.Arr(response.Get("findings")).FirstOrDefault(x => x.Text("entry_id") == unit.Id && x.Text("fix") == "entry" && x.Text("suggestion").Length > 0);
                if (next is null) { _notice = "按你说的，这一段的标题不用再改。"; return; }
                finding.Suggestion = next.Text("suggestion");
                if (next.Text("caption").Length > 0) finding.Caption = next.Text("caption");
                if (next.Text("detail").Length > 0) finding.Detail = next.Text("detail");
                return;
            }
            var body = new JsonObject
            {
                ["section"] = unit.SectionPayload,
                ["context"] = ResumeCheck.Context(_state.Units, unit.Id),
                ["reference"] = new JsonObject { ["kind"] = "general" },
                ["line_id"] = finding.LineId,
                ["instruction"] = instruction,
                ["answers"] = new JsonArray(),
            };
            if (finding.Suggestion is { } current) body["current_text"] = current.Length > ResumeCheck.LineChars ? current[..ResumeCheck.LineChars] : current;
            var rewrite = await App.Session.Api.CareerRequestAsync($"/api/resumes/{_resumeId}/section-review:rewrite", "POST", body: body);
            if (S.Arr(rewrite.Get("variants")).FirstOrDefault() is not { } variant)
            {
                var missing = S.Arr(rewrite.Get("missing")).Select(x => x.String()).OfType<string>().ToList();
                _notice = missing.Count == 0 ? "这次没改出来，换个说法试试。" : $"还差：{string.Join("、", missing)}";
                return;
            }
            finding.Suggestion = variant.Text("text");
            finding.Risky = S.Arr(variant.Get("risky_terms")).Select(x => x.String()).OfType<string>().ToList();
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _notice = ResumeCheck.ErrorMessage(error).Message;
        }
        finally { _busy = false; Render(); _changed(); }
    }
}
