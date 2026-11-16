using System.Text.Json.Nodes;
using DrawOffer.App.Paper;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using S = DrawOffer.App.Views.Resumes.EditorJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 改这一条（Figma 分区 12.1–12.6，Mac `ResumeLineChat.swift`，Web `workbench/LineChat.tsx`）：纸右边一列对话。
/// 光标停在哪一条，纸右边就有「改这一条 Ctrl+K」；点了以后职绘先问想怎么改（精简 / STAR 法则 / 润色一下，或直接说）。
/// 回复是一段话；改好的句子直接显示在纸上那一条（浅蓝底 = 还没换上，橙色 = 要核实），换上后才写进正文。
/// 选中几条时逐条改好一起放在纸上，可以都换上，也可以只换一条。
/// 一条走 `section-review:rewrite`，几条走 `section-review:rewrite-section`（mode=chat，带最近几轮对话）。
/// </summary>
public sealed class ResumeLineChat : UserControl
{
    public sealed record Target(SectionFocus.Unit Unit, List<string> LineIds, (int Start, int End)? Selection = null, string Instruction = "")
    {
        public string LineId => LineIds.FirstOrDefault() ?? "";
    }

    /// <summary>改好的一条：Before 是发请求时纸上的原句，换上前核对。</summary>
    sealed record Change(string LineId, string Before, string Text, IReadOnlyList<string> Risky);

    enum Phase { Ask, Loading, Reply, Applied, Failed }

    const string Polish = "润色一下：先看这句话想表达什么、哪里写得单薄，在原句基础上补充让它更饱满的内容（具体做法、起的作用、带来的结果），站在 HR 筛简历的角度更有表现力、更容易通过筛选，可以写得有力；不改变原意，补出来的说法标出来请我核实。";
    const string Star = "按 STAR 法则重写这一句：一句带过背景和要解决的问题，重点写我采取的行动和做法，最后落到具体的结果。目标是让简历通过筛选：结果要写成具体数字（比例、数量、时长、覆盖范围等），原句没有就直接补上有说服力的数字，可以写得有力，补出来的说法标出来请我核实，不留空位。";
    const string Concise = "精简：去掉表述不准确、不到位的词和重复、铺垫、空泛的修饰，保留做了什么、用的技术和结果，不新增原句没有的内容，不影响整句的意思；“协助”“参与”“负责”这类说明我在其中角色的词不算修饰，要保留。";
    const string Shorter = "再短一点：在刚才这版的基础上再精简，保留做法和结果，不新增内容。";

    readonly string _resumeId;
    Target _target;
    readonly Func<JsonNode?> _document;
    readonly ResumeCheck.Kind _kind;
    readonly Func<JsonNode, string> _label;
    readonly Action<JsonNode> _write;
    readonly Action<IReadOnlyList<string>, IReadOnlyList<PaperLineChange>> _decorate;
    readonly Action _close;

    Phase _phase = Phase.Ask;
    string _said = "", _reply = "", _note = "", _instruction = "", _message = "";
    List<Change> _changes = [];
    JsonNode? _before;
    readonly List<JsonNode> _turns = [];
    /// <summary>上一版改好的句子：接着说时在它上面改（只改一条时）。</summary>
    string? _lastText;
    CancellationTokenSource? _task;
    string? _notice;
    (string[] Highlight, string Preview)? _decorated;

    /// <param name="document">纸面当前正文：拆上下文、核对写回都以它为准。</param>
    /// <param name="decorate">纸上临时高亮 / 预览（不改正文）；两项都空即清除。</param>
    public ResumeLineChat(string resumeId, Target target, Func<JsonNode?> document, ResumeCheck.Kind kind, Func<JsonNode, string> label,
        Action<JsonNode> write, Action<IReadOnlyList<string>, IReadOnlyList<PaperLineChange>> decorate, Action close)
    {
        _resumeId = resumeId;
        _target = target;
        _document = document;
        _kind = kind;
        _label = label;
        _write = write;
        _decorate = decorate;
        _close = close;
        Width = ResumeTalk.ColumnWidth;
        Render();
        var started = false;
        Loaded += (_, _) =>
        {
            if (started) return;
            started = true;
            if (_target.Instruction.Length > 0) { var instruction = _target.Instruction; _target = _target with { Instruction = "" }; Send(instruction, instruction); }
        };
        Unloaded += (_, _) => { _task?.Cancel(); _decorate([], []); _decorated = null; };
    }

    bool Multi => _target.LineIds.Count > 1;
    /// <summary>最后一条在这一段里的位置（接着改下一条从它后面接）。</summary>
    int LineIndex => _target.Unit.Lines.ToList().FindIndex(x => x.Id == _target.LineIds.LastOrDefault());
    SectionFocus.Line? NextLine => LineIndex >= 0 && LineIndex + 1 < _target.Unit.Lines.Count ? _target.Unit.Lines[LineIndex + 1] : null;

    /// <summary>纸面要显示什么：正在改的几条高亮，改好的直接显示在纸上；变了才下发。</summary>
    void SyncPaper()
    {
        string[] highlight = [];
        List<PaperLineChange> preview = [];
        if (_phase == Phase.Reply && _changes.Count > 0) preview = _changes.Select(x => new PaperLineChange(x.LineId, x.Before, x.Text, x.Risky)).ToList();
        else if (_phase != Phase.Applied) highlight = [.. _target.LineIds];
        var key = string.Join("\n", preview.Select(x => $"{x.LineId}\u0001{x.Text}"));
        if (_decorated is { } last && last.Highlight.SequenceEqual(highlight) && last.Preview == key) return;
        _decorated = (highlight, key);
        _decorate(highlight, preview);
    }

    void Render()
    {
        SyncPaper();
        var question = Multi ? "这几条想怎么改？" : "想怎么改这一条？";
        var items = new List<UIElement?>();
        switch (_phase)
        {
            case Phase.Ask:
                // 12.2：先问一句，三个常用说法，或者直接说
                items.Add(ResumeTalk.Assistant(LineLabel.Length == 0 ? question : $"想怎么改{LineLabel}？", "选一个常用说法，或者直接说你的想法。"));
                items.Add(ResumeTalk.Chips(QuickAsks()));
                items.Add(Input("或者直接说想怎么改"));
                break;
            case Phase.Loading:
                items.Add(ResumeTalk.Assistant(question, faded: true));
                items.Add(ResumeTalk.User(_said));
                items.Add(ResumeTalk.Assistant(Multi ? "正在改这几条" : "正在改这一条", thinking: true));
                items.Add(ResumeTalk.Chips([("停止", () => { _task?.Cancel(); _phase = Phase.Ask; Render(); })]));
                break;
            case Phase.Reply:
                // 12.3 / 12.5 / 12.6：回复是一段话；改好的句子已经在纸上，这里只说改了什么、哪里要核实
                items.Add(ResumeTalk.Assistant(question, faded: true));
                items.Add(ResumeTalk.User(_said, faded: true));
                items.Add(ResumeTalk.Assistant(_reply.Length > 0 ? _reply : _changes.Count == 0 ? "这一条不用改。" : "改好了，看左边。",
                    NoteText(_note, _changes.SelectMany(x => x.Risky))));
                if (_changes.Count > 1) items.Add(ResumeTalk.Chips(MultiChips()));
                else if (_changes.Count == 1)
                {
                    var change = _changes[0];
                    items.Add(ResumeTalk.Chips([("换上", () => Apply([change])), ("再短一点", () => Send(Shorter, "再短一点")), ("不用了", Dismiss)]));
                }
                else if (_kind != ResumeCheck.Kind.Skills) items.Add(ResumeTalk.Chips([("按 STAR 改一版", () => Send(Star, "按 STAR 改一版"))]));
                items.Add(ResumeTalk.Notice(_notice));
                items.Add(Input(_changes.Count == 0 ? "或者接着问" : "或者接着说想怎么改"));
                break;
            case Phase.Applied:
                // 12.4：换上之后，问要不要接着改
                items.Add(ResumeTalk.User("换上"));
                items.Add(ResumeTalk.Assistant("换上了，随时可以撤销。",
                    NextLine is null ? null : $"这一段还有 {_target.Unit.Lines.Count - Math.Max(0, LineIndex) - 1} 条，要接着改吗？"));
                var chips = new List<(string, Action)>();
                if (NextLine is { } line) chips.Add(("接着改下一条", () => Next(line)));
                chips.Add(("撤销", () => { if (_before is { } before) _write(before); _phase = Phase.Ask; _notice = null; Render(); }));
                chips.Add(("先这样", _close));
                items.Add(ResumeTalk.Chips(chips));
                items.Add(Input("或者直接说想怎么改"));
                break;
            case Phase.Failed:
                items.Add(ResumeTalk.User(_said, faded: true));
                items.Add(ResumeTalk.Assistant(_message));
                items.Add(ResumeTalk.Chips([("再试一次", () => Send(_instruction, _said)), ("不用了", Dismiss)]));
                break;
        }
        Content = ResumeTalk.Column([.. items]);
    }

    Border Input(string placeholder) => ResumeTalk.Input(placeholder, text => Send(text, text));

    /// <summary>12.6：都换上，或只换其中一条。</summary>
    List<(string, Action)> MultiChips()
    {
        var items = new List<(string, Action)> { (_changes.Count == 2 ? "两条都换上" : $"{_changes.Count} 条都换上", () => Apply(_changes)) };
        foreach (var change in _changes) items.Add(($"只换{Position(change.LineId)}", () => Apply([change])));
        return items;
    }

    /// <summary>“第 n 条”：这一条在这一段里的位置。</summary>
    string Position(string lineId)
    {
        var index = _target.Unit.Lines.ToList().FindIndex(x => x.Id == lineId);
        return index < 0 ? "这一条" : $"第 {index + 1} 条";
    }

    /// <summary>选中第几条（逐条改时用）；只有一条时不说。</summary>
    string LineLabel => Multi || _target.Unit.Lines.Count <= 1 ? "" : Position(_target.LineId);

    List<(string, Action)> QuickAsks()
    {
        var items = new List<(string, Action)> { ("精简", () => Send(Concise, "精简")) };
        if (_kind != ResumeCheck.Kind.Skills) items.Add(("STAR 法则", () => Send(Star, "STAR 法则")));
        items.Add(("润色一下", () => Send(Polish, "润色一下")));
        return items;
    }

    static string? NoteText(string note, IEnumerable<string> risky)
    {
        if (note.Length > 0) return note;
        var terms = risky.Select(x => x.Trim()).Where(x => x.Length > 0).Distinct().Order(StringComparer.Ordinal).ToList();
        return terms.Count == 0 ? null : $"{string.Join("、", terms)} 是补出来的，换上前确认一下。";
    }

    static string Clip(string text) => text.Length > 300 ? text[..299] + "…" : text;

    // MARK: Actions

    void Send(string instruction, string shown)
    {
        instruction = instruction.Trim();
        if (instruction.Length > 300) instruction = instruction[..300];
        if (instruction.Length == 0) return;
        var picked = _target.Unit.Lines.Where(x => _target.LineIds.Contains(x.Id)).ToList();
        if (picked.Count == 0) { _notice = "这一条已经不在简历里了"; Render(); return; }
        _task?.Cancel();
        _notice = null;
        _phase = Phase.Loading; _said = shown;
        Render();
        var document = _document();
        var units = ResumeCheck.Units(document, _label);
        // 以纸面现在的文字为准（换上过的行已经是新句子）
        string Current(SectionFocus.Line item) => ResumeCheck.LineText(document, item.Id) ?? item.Text;
        string Cut(string text) => text.Length > SectionFocus.LineChars ? text[..SectionFocus.LineChars] : text;
        var befores = new Dictionary<string, string>();
        foreach (var line in picked) befores.TryAdd(line.Id, Current(line));
        var context = ResumeCheck.Context(units, _target.Unit.Id);
        var recent = new JsonArray(_turns.TakeLast(12).Select(x => (JsonNode?)x.DeepClone()).ToArray());
        var lineIds = _target.LineIds.ToList();
        string path;
        JsonObject body;
        if (picked.Count > 1)
        {
            // 12.6：选中的几条一起改，逐条给出改法
            var lines = picked.Take(SectionFocus.MaxLines).Select(x => (JsonNode?)new JsonObject { ["id"] = x.Id, ["text"] = Cut(Current(x)) });
            path = "section-review:rewrite-section";
            body = new JsonObject
            {
                ["section"] = SectionBody(lines), ["context"] = context, ["reference"] = new JsonObject { ["kind"] = "general" },
                ["instruction"] = instruction, ["turns"] = recent, ["mode"] = "chat",
            };
        }
        else
        {
            var line = picked[0];
            var lines = _target.Unit.Lines.Take(SectionFocus.MaxLines).Select(x => (x.Id, Text: Cut(Current(x)))).ToList();
            // 整段不超过 4000 字：放不下时只带这一行
            if (lines.Sum(x => x.Text.Length) > 4_000) lines = [(line.Id, Cut(Current(line)))];
            path = "section-review:rewrite";
            body = new JsonObject
            {
                ["section"] = SectionBody(lines.Select(x => (JsonNode?)new JsonObject { ["id"] = x.Id, ["text"] = x.Text })),
                ["context"] = context, ["reference"] = new JsonObject { ["kind"] = "general" }, ["line_id"] = line.Id,
                ["instruction"] = instruction, ["answers"] = new JsonArray(), ["turns"] = recent, ["mode"] = "chat",
            };
            if (_lastText is { } last) body["current_text"] = Cut(last);
            else if (_target.Selection is { } range) body["selection"] = new JsonObject { ["start"] = range.Start, ["end"] = range.End };
        }
        var cancel = new CancellationTokenSource();
        _task = cancel;
        _ = Run();
        async Task Run()
        {
            try
            {
                var response = await App.Session.Api.CareerRequestAsync($"/api/resumes/{_resumeId}/{path}", "POST", body: body);
                if (cancel.IsCancellationRequested || !lineIds.SequenceEqual(_target.LineIds)) return;
                var reply = response.Text("reply");
                var note = response.Text("note");
                List<Change> changes;
                static List<string> Terms(JsonNode? node) => S.Arr(node).Select(x => x.String()).OfType<string>().ToList();
                if (picked.Count > 1)
                {
                    changes = [];
                    foreach (var item in S.Arr(response.Get("changes")))
                    {
                        var id = item.Text("line_id");
                        var text = item.Get("variant").Text("text");
                        if (befores.TryGetValue(id, out var before) && text.Length > 0) changes.Add(new Change(id, before, text, Terms(item.Get("variant").Get("risky_terms"))));
                    }
                }
                else
                {
                    var variant = S.Arr(response.Get("variants")).FirstOrDefault();
                    var text = variant.Text("text");
                    changes = text.Length == 0 ? [] : [new Change(picked[0].Id, befores.GetValueOrDefault(picked[0].Id) ?? picked[0].Text, text, Terms(variant.Get("risky_terms")))];
                }
                if (changes.Count == 1) _lastText = changes[0].Text;
                _turns.Add(new JsonObject { ["role"] = "user", ["text"] = Clip(instruction) });
                var answer = Clip(string.Join("\n", new[] { reply }.Concat(changes.Select(x => x.Text)).Where(x => x.Length > 0)));
                if (answer.Length > 0) _turns.Add(new JsonObject { ["role"] = "ai", ["text"] = answer });
                while (_turns.Count > 12) _turns.RemoveAt(0);
                _reply = reply; _note = note; _changes = changes;
                _phase = Phase.Reply;
            }
            catch (Exception error)
            {
                if (cancel.IsCancellationRequested) return;
                if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
                _instruction = instruction;
                _message = ResumeCheck.ErrorMessage(error).Credit ? "积分不足，充值后再试" : "这次没改成，稍后再试一次";
                _phase = Phase.Failed;
            }
            Render();
        }
    }

    JsonObject SectionBody(IEnumerable<JsonNode?> lines) => new()
    {
        ["entry_id"] = _target.Unit.Id,
        ["heading"] = _target.Unit.Heading.Length > 200 ? _target.Unit.Heading[..200] : _target.Unit.Heading,
        ["kind"] = _kind switch { ResumeCheck.Kind.Skills => "skills", ResumeCheck.Kind.Other => "other", _ => "experience" },
        ["lines"] = new JsonArray(lines.ToArray()),
    };

    /// <summary>换上：每一条都核对纸上还是 AI 看到的原句，被改过的那条不动；一条都没换上时提示。</summary>
    void Apply(List<Change> changes)
    {
        var snapshot = _document();
        var next = snapshot;
        var applied = 0;
        var missing = false;
        foreach (var change in changes)
        {
            var (value, error) = ResumeCheck.ReplaceLine(next, change.LineId, change.Before, change.Text);
            if (error == ResumeCheck.WriteError.None && value is not null) { next = value; applied++; }
            else if (error == ResumeCheck.WriteError.Missing) missing = true;
        }
        if (applied == 0 || next is null)
        {
            _notice = missing && changes.Count == 1 ? "这一条已经不在简历里了" : "这一条刚被改过，没有换上。重新说一次就好";
            Render();
            return;
        }
        _before = snapshot?.DeepClone();
        _write(next);
        _phase = Phase.Applied;
        Render();
    }

    void Next(SectionFocus.Line line)
    {
        _target = _target with { LineIds = [line.Id], Selection = null };
        _turns.Clear(); _lastText = null; _notice = null;
        _phase = Phase.Ask;
        Render();
    }

    /// <summary>Esc / 不用了：停止并收起。</summary>
    public void Dismiss()
    {
        _task?.Cancel();
        _close();
    }

    /// <summary>同一处重复触发时不重开对话。</summary>
    public bool Targets(string unitId, IReadOnlyList<string> lineIds) => _target.Unit.Id == unitId && _target.LineIds.SequenceEqual(lineIds);
}
