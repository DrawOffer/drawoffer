using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>场次画面里的一个阶段：父级刷新到新的场次数据时交给它。</summary>
internal interface IMockStage { void Update(JsonNode detail); }

/// <summary>
/// 面试中（Windows 稿 09 · 03–07；Mac `MockSessionV2`、Web `MockInterviewPage` 的 `InterviewRoute`）：按状态分到准备题目、设备检测、文字 / 语音作答和结束页。
/// 面试中是无侧栏的全屏画面；完成后交给复盘。
/// </summary>
internal sealed class MockSessionView : UserControl
{
    readonly string _id;
    readonly Action _home;
    readonly Action<string> _report, _open;
    readonly MockViewLifetime _life;
    JsonNode? _detail;
    string? _failed;
    bool _paused, _polling;
    string _stageKey = "";
    FrameworkElement? _stage;

    public MockSessionView(string id, Action home, Action<string> report, Action<string> open)
    {
        (_id, _home, _report, _open) = (id, home, report, open);
        Background = Brush(V3.White);
        _life = new MockViewLifetime(this, home);
        Content = new Grid { Background = Brush(V3.White) };
        Loaded += (_, _) => _ = Load();
    }

    async Task Load()
    {
        try
        {
            var value = await _life.Request($"/api/mock-interviews/{_id}");
            _detail = value.Get("mock_interview");
            _failed = null;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { _failed = MP.Error(error); }
        if (!_life.Alive) return;
        Render();
        if (!_polling) _ = Poll();
    }

    /// <summary>准备题目与生成评估由后台任务完成，页面没有推送，2.5 秒轮询一次到状态变化。</summary>
    async Task Poll()
    {
        _polling = true;
        while (_life.Alive && _detail.Text("status") is "preparing" or "evaluating")
        {
            await Task.Delay(2500);
            if (!_life.Alive) break;
            if (!_paused) await Load();
        }
        _polling = false;
    }

    void Changed() => _ = Load();
    void Pause(bool value) => _paused = value;

    void Render()
    {
        if (_detail is null)
        {
            if (_failed is null) return;
            _stageKey = "failed";
            Content = VStack(10,
                Serif(_failed.Contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来", 22, MP.Ink).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                Sans(_failed, 13, MP.Sub).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                MP.Dark("返回模拟面试", _home).Also(b => b.HorizontalAlignment = HorizontalAlignment.Center).Top(6))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            return;
        }
        var status = _detail.Text("status");
        var voice = _detail.Text("answer_mode") == "voice";
        var key = status == "completed" ? "report"
            : voice && status is "preparing" or "preparation_failed" or "in_progress" ? "voice"
            : status is "preparing" or "preparation_failed" ? "prep"
            : status == "in_progress" ? "text" : "closing";
        if (key == "report") { _report(_detail.Display("id")); return; }
        if (key == _stageKey && _stage is IMockStage stage) { stage.Update(_detail); return; }
        _stageKey = key;
        _stage = key switch
        {
            "voice" => new MockVoiceSession(_detail, _life, Changed, _home, Pause),
            "prep" => new MockPrepStage(_detail, _life, Changed, _home),
            "text" => new MockTextSession(_detail, _life, Changed, Pause),
            _ => new MockClosingStage(_detail, _life, Changed, _home, _open),
        };
        Content = _stage;
    }
}

// MARK: 准备题目（Windows 稿 09 · 03 开始前 03.01–03.02、04 选题动效；Mac / Web `PrepStage`）

internal sealed class MockPrepStage : UserControl, IMockStage
{
    static readonly string[] Titles = ["面试官在读你的简历", "从题库里为你挑题", "第一道问题快好了"];
    static readonly Dictionary<string, string> Pace = new()
    {
        ["quiet"] = "只挑最影响通过的点，不再试探新点", ["near"] = "先补短板，顺带确认几处拿不准的",
        ["far"] = "先摸清你还拿不准的点，再集中补短板", ["none"] = "还没有约面试，按两周的节奏：先摸清你还拿不准的点",
    };

    JsonNode _detail;
    readonly MockViewLifetime _life;
    readonly Action _changed, _home;
    readonly Action? _checkDevice;
    readonly MockPrepCards _cards = new();
    readonly TextBlock _rotating;
    bool _busy;
    int _lastStep = -1;
    DateTime _lineStart = DateTime.UtcNow;

    public MockPrepStage(JsonNode detail, MockViewLifetime life, Action changed, Action home, Action? checkDevice = null)
    {
        (_detail, _life, _changed, _home, _checkDevice) = (detail, life, changed, home, checkDevice);
        _rotating = Sans("", 15, MP.Sub).LineHeight(26);
        _rotating.Width = 1120; _rotating.TextAlignment = TextAlignment.Center;
        MockFull.Every(this, TimeSpan.FromMilliseconds(300), Rotate);
        Render();
    }

    public void Update(JsonNode detail) { _detail = detail; Render(); }

    JsonNode? Prep => _detail.Get("prep") is JsonObject prep ? prep : null;
    bool Failed => _detail.Text("status") == "preparation_failed";
    bool HasJob => _detail.Text("job_title").Length > 0 || _detail.Text("company_name").Length > 0;
    int Step
    {
        get
        {
            if (Failed && _detail.Text("failed_stage") switch { "analysis" => 0, "plan" => 1, "opening" => 2, _ => -1 } is var stage and >= 0) return stage;
            if (Prep is not { } prep) return 0;
            return prep.Text("stage") == "select" ? 1 : 2;
        }
    }

    void Render()
    {
        if (Step != _lastStep) { _lastStep = Step; _lineStart = DateTime.UtcNow; }
        var canvas = MockFull.Canvas();
        MockFull.Head(canvas, _detail, back: ("面试设置", _busy, () => { if (Failed) BackToSettings(); else AskBack(); }));
        MockFull.Center(canvas, $"准备题目 · {Step + 1} / 3", 114);
        MockFull.Center(canvas, Failed ? "面试官没能准备好题目" : Titles[Step], 138, 46, 64, MP.Ink, serif: true);
        if (Failed)
        {
            var reason = MP.Messages.GetValueOrDefault(_detail.Text("error_code")) ?? "模型服务暂时没有响应";
            MockFull.Center(canvas, $"{reason}，这一次没有扣积分。", 210, 15, 26, MP.Sub);
        }
        else
        {
            if (_rotating.Parent is Canvas old) old.Children.Remove(_rotating);
            MockFull.Put(canvas, _rotating, 124, 210);
            Rotate();
        }
        if (_cards.Parent is Canvas previous) previous.Children.Remove(_cards);
        _cards.Update(Prep, Failed, HasJob);
        MockFull.Put(canvas, _cards, 0, 0);
        UIElement[] right = Failed
            ? [MP.Dark(_busy ? "正在重新准备…" : "重新准备", () => Run(() => Command("retry")), enabled: !_busy)]
            : _detail.Text("answer_mode") == "voice" && _checkDevice is not null ? [MP.Ghost("先试一下麦克风", _checkDevice)] : [];
        MockFull.Foot(canvas, _detail.Text("practice_goal"), null, right);
        Content = MockFull.Stage(canvas);
    }

    /// <summary>标题下的小字每 4.5 秒换一句，讲这一步实际在按什么挑；换步骤时从第一句重新开始。</summary>
    void Rotate()
    {
        if (Failed) return;
        var lines = Step == 0 ? ReadingLines() : Step == 1 && Prep is { } prep ? SelectingLines(prep) : OpeningLines();
        var elapsed = (DateTime.UtcNow - _lineStart).TotalSeconds;
        var index = lines.Count < 2 ? 0 : (int)(elapsed / 4.5) % lines.Count;
        var fading = lines.Count >= 2 && elapsed % 4.5 > 4.2;
        _rotating.Text = lines.Count == 0 ? "" : lines[index];
        _rotating.Opacity = fading ? 0 : 1;
    }

    List<string> ReadingLines()
    {
        var focus = _detail.Get("practice_focus").Text("label").NonEmpty();
        var lines = new List<string>
        {
            "通常 20–40 秒。可以先离开页面，准备好了会提醒你。",
            HasJob ? "先看这场属于什么方向，再找出岗位要求里写到的考点" : "先看你的经历属于什么方向，再找这个方向常考的点",
            "简历里写到的项目和经历，会挑出来准备追问",
        };
        if (focus is not null) lines.Add($"你选的「{focus}」会放在最前面问");
        else if (_detail.Bool("has_past_practice")) lines.Add("也会翻一遍以前的练习：上次没答好的点，这次会再确认一次");
        return lines;
    }

    List<string> SelectingLines(JsonNode prep)
    {
        var picks = prep.Items("picks");
        var tags = picks.Select(p => p.Text("tag")).ToHashSet();
        var gap = picks.Any(p => p.Text("tag") == "job" && p.Text("note") == "简历里还没有写到");
        var who = (_detail.Text("company_name") + _detail.Text("stage_label")).NonEmpty() ?? "面试";
        var days = prep.Number("days_left");
        var when = days is { } d ? d <= 0 ? $"今天就是{who}" : $"离{who}还有 {(int)d} 天" : null;
        var pace = Pace.GetValueOrDefault(prep.Text("strategy")) ?? $"按{(HasJob ? "岗位要求和你的经历" : "你的经历和这个方向常考的点")}为你挑题";
        var lines = new List<string> { when is null ? pace : $"{when}，{pace}" };
        if (tags.Contains("retest")) lines.Add("上次没答好的点会再问一次，看看这次有没有补上");
        if (tags.Contains("probe")) lines.Add("还拿不准你掌握没有的点，会补问一题确认");
        if (tags.Contains("focus")) lines.Add("你点名要练的，优先放进这一场");
        if (gap) lines.Add("岗位要求里有、简历里还没写到的点，也会问到");
        else if (tags.Contains("job")) lines.Add("岗位要求里写到的点优先挑");
        if (tags.Contains("resume")) lines.Add("从你的经历里挑一两段深挖，问做法和结果");
        if (tags.Contains("basics")) lines.Add("再配几道这个方向常考的基础");
        if (tags.Contains("competency")) lines.Add("留一道综合题，看沟通、协作和推进");
        return lines;
    }

    List<string> OpeningLines()
    {
        var lines = new List<string> { "考点已经挑好，面试官正在组织第一问。" };
        if (Prep.Text("first").NonEmpty() is { } first) lines.Add($"第一题从「{first}」问起");
        if (_detail.Bool("follow_up_enabled")) lines.Add("答完之后，面试官会顺着你的回答追问");
        if (_detail.Text("answer_mode") == "voice") lines.Add("趁这会儿可以先试一下麦克风");
        return lines;
    }

    Task<JsonNode> Command(string name) => _life.Request($"/api/mock-interviews/{_detail.Display("id")}/{name}", "POST");

    async void Run(Func<Task> action, Action? after = null)
    {
        _busy = true; Render();
        try { await action(); after?.Invoke(); _changed(); }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice("操作没有完成", MP.Error(error), error: true); }
        _busy = false;
        if (_life.Alive) Render();
    }

    void AskBack()
    {
        if (XamlRoot is null) return;
        MP.Confirm(XamlRoot, "返回修改设置？", "题目还在准备，返回后这场记为已放弃，不扣积分。", "返回改设置", BackToSettings, "继续准备");
    }

    void BackToSettings() => Run(() => Command("abandon"), _home);
}

// MARK: 结束（Windows 稿 09 · 07 结束 07.01 整理报告、07.02 放弃 / 没能生成；Mac / Web `ClosingStage`）

internal sealed class MockClosingStage : UserControl, IMockStage
{
    static readonly double[] StatX = [380, 684, 988];
    JsonNode _detail;
    readonly MockViewLifetime _life;
    readonly Action _changed, _home;
    readonly Action<string> _open;
    bool _busy;

    public MockClosingStage(JsonNode detail, MockViewLifetime life, Action changed, Action home, Action<string> open)
    {
        (_detail, _life, _changed, _home, _open) = (detail, life, changed, home, open);
        Render();
    }

    public void Update(JsonNode detail) { _detail = detail; Render(); }

    void Render()
    {
        var status = _detail.Text("status");
        var failed = status == "evaluation_failed";
        var abandoned = status == "abandoned";
        var voice = _detail.Text("answer_mode") == "voice";
        var canvas = MockFull.Canvas();
        if (abandoned || failed)
        {
            MockFull.Head(canvas, _detail, back: ("模拟面试", false, _home));
            MockFull.Center(canvas, abandoned ? "这场面试已放弃" : "评估报告没能生成", 314, 46, 64, MP.Ink, serif: true);
            MockFull.Center(canvas, abandoned ? $"没有生成报告{(voice ? "，录音已删除" : "")}。" : $"作答{(voice ? "和录音" : "")}都保存了，重新评估不另扣积分。", 388, 15, 26, MP.Sub);
            MockFull.Foot(canvas, null, null, abandoned
                ? MP.Dark(_busy ? "正在准备…" : "用同样设置重新开始", Restart, enabled: !_busy)
                : MP.Dark(_busy ? "正在重新评估…" : "重新评估", Retry, enabled: !_busy));
        }
        else
        {
            var questions = _detail.Items("questions");
            var mains = questions.Count(q => q.Text("kind") == "main" && !MockMap.IsIntro(_detail, q));
            var follows = questions.Count(q => q.Text("kind") == "follow_up");
            var points = questions.Sum(q => q.Items("notes").Count);
            var started = Json.Date(_detail.Text("started_at")) ?? Json.Date(_detail.Text("created_at")) ?? DateTimeOffset.UtcNow;
            var finished = Json.Date(_detail.Text("finished_at")) ?? DateTimeOffset.UtcNow;
            MockFull.Head(canvas, _detail);
            MockFull.Center(canvas, "用时 " + MockSession.Mmss((finished - started).TotalSeconds), 216);
            MockFull.Center(canvas, "面试结束，辛苦了", 244, 46, 64, MP.Ink, serif: true);
            MockFull.Center(canvas, "面试官在把笔记整理成评估报告，约 1 分钟。", 318, 15, 26, MP.Sub);
            MockFull.Put(canvas, new MockLiveWave(MockLiveWave.Tone.Rest), 234, 370);
            var items = new[] { (mains, "主问题"), (follows, "次追问"), (points, "条要点") };
            for (var i = 0; i < items.Length; i++)
            {
                var stat = HStack(3, Serif(items[i].Item1.ToString(), 28, MP.Ink), Sans(items[i].Item2, 13, MP.Fnt).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 6));
                stat.HorizontalAlignment = HorizontalAlignment.Center;
                MockFull.Put(canvas, new Grid { Width = 200, Height = 38, Children = { stat } }, StatX[i] - 100, 484);
            }
            MockFull.Foot(canvas, null, Sans("报告好了会出现在模拟面试首页。", 13, MP.Fnt), MP.Dark("先去忙，好了提醒我", _home));
        }
        Content = MockFull.Stage(canvas);
    }

    Task<JsonNode> Command(string name) => _life.Request($"/api/mock-interviews/{_detail.Display("id")}/{name}", "POST");

    async void Retry()
    {
        _busy = true; Render();
        try { await Command("retry"); _changed(); }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice("操作没有完成", MP.Error(error), error: true); }
        _busy = false; if (_life.Alive) Render();
    }

    async void Restart()
    {
        _busy = true; Render();
        try { _open((await Command("repeat")).Get("mock_interview").Display("id")); return; }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice("操作没有完成", MP.Error(error), error: true); }
        _busy = false; if (_life.Alive) Render();
    }
}

// MARK: 文字面试（Windows 稿 09 · 06 文字面试 06.01–06.11；Mac `MockTextSession`、Web `TextSessionV2`）

/// <summary>
/// 和语音面试同一套画面，声纹的位置换成无框写字区，发送在底部右侧；面试官说话时没有写字区。
/// 发送后到面试官开口之前是思考界面：题目收起，回答留在原处变灰，笔记到了标出被记下的原话。
/// </summary>
internal sealed class MockTextSession : UserControl, IMockStage
{
    const int MaxAnswer = 8000;
    enum Phase { Answer, Sent, Asking, Closing }

    JsonNode _detail;
    readonly MockViewLifetime _life;
    readonly Action _changed;
    readonly Action<bool> _pause;
    readonly TextBox _box;
    readonly MockVoiceRecorder _voice = new();
    Phase _phase = Phase.Answer;
    string? _sent;
    string _askText = "", _speechSession = "";
    int _shown = int.MaxValue, _noted;
    string? _busy;
    bool _turnReady, _voiceFailed, _listening, _recognizing;
    List<string> _quotes = [];
    string _questionId = "";
    TextBlock? _clock, _question, _live, _count;
    V3Button? _send;

    public MockTextSession(JsonNode detail, MockViewLifetime life, Action changed, Action<bool> pause)
    {
        (_detail, _life, _changed, _pause) = (detail, life, changed, pause);
        _box = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = SansFamily, FontSize = 17, MaxLength = MaxAnswer,
            PlaceholderText = "写下你的回答", BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0),
            Width = 903, Height = 300, Foreground = Brush(MP.Ink),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_box, "你的回答");
        ScrollViewer.SetVerticalScrollBarVisibility(_box, ScrollBarVisibility.Auto);
        _box.TextChanged += (_, _) => Refresh();
        _box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (shift) return;
            e.Handled = true; Send();
        };
        _voice.Changed += () => DispatcherQueue.TryEnqueue(() => { if (_live is not null) SetLive(); });
        _voice.Failed += _ => DispatcherQueue.TryEnqueue(() => { _listening = false; _recognizing = false; _voiceFailed = true; Render(); });
        Unloaded += (_, _) => _voice.Cancel();
        MockFull.Every(this, TimeSpan.FromSeconds(1), () => { if (_clock is not null) _clock.Text = MockSessionText.Elapsed(_detail); });
        MockFull.Every(this, TimeSpan.FromMilliseconds(40), Type);
        _questionId = Question.Display("id");
        Render();
    }

    public void Update(JsonNode detail)
    {
        if (_phase == Phase.Sent) return;
        _detail = detail;
        Render();
    }

    JsonNode? Question => MockSession.Current(_detail);
    bool NeedsReply => _detail.Bool("needs_reply") && _phase == Phase.Answer;
    bool Locked => _phase != Phase.Answer || Question is null || NeedsReply || _busy is not null;
    string Path(string command) => $"/api/mock-interviews/{_detail.Display("id")}/{command}";

    void Render()
    {
        if (Question.Display("id") is var qid && qid != _questionId) { _questionId = qid; _voice.Cancel(); _listening = false; _voiceFailed = false; }
        var shownQuestion = Question ?? MockSession.LastAsked(_detail);
        var typing = _phase is Phase.Asking or Phase.Closing;
        var writing = _phase == Phase.Answer && !NeedsReply && Question is not null;
        var (statusText, statusColor) = _phase == Phase.Asking ? ("面试官在问", MP.Sub)
            : _phase == Phase.Closing ? ("面试官在说结束语", MP.Sub)
            : NeedsReply ? ("面试官的回复没生成，你的回答已经保存", MP.Orange)
            : _listening ? ("正在听 · 再点一下停止", MP.Blue)
            : ("轮到你", MP.Sub);
        var canvas = MockFull.Canvas();
        _clock = MockFull.Head(canvas, _detail, timer: true, back: null,
            MP.Link("跳过此题", () => { if (XamlRoot is not null) MockSessionDialogs.Skip(XamlRoot, Skip); }, enabled: () => !Locked),
            MP.Link("放弃", () => { if (XamlRoot is not null) MockSessionDialogs.Abandon(XamlRoot, false, () => End("abandon")); }, enabled: () => _busy is null && _phase != Phase.Closing),
            MP.Ghost("结束并评估", () => { if (XamlRoot is not null) MockSessionDialogs.Finish(XamlRoot, _detail, () => End("finish")); }, 38, _busy is null && _phase is not (Phase.Closing or Phase.Sent)));
        _question = null;
        if (_phase == Phase.Sent) Thinking(canvas, shownQuestion);
        else
        {
            MockFull.Center(canvas, _phase == Phase.Closing ? "面试结束" : MockSessionText.Eyebrow(_detail, shownQuestion), 175);
            _question = MockFull.BigQuestion(canvas, typing ? _askText : shownQuestion.Text("content"), typing ? _shown : int.MaxValue);
            MockFull.Center(canvas, statusText, 360, 14, 20, statusColor);
        }
        _live = null;
        if (_box.Parent is Canvas old) old.Children.Remove(_box);
        if (writing)
        {
            if (_listening || _recognizing)
            {
                _live = new TextBlock { FontFamily = SansFamily, FontSize = 17, LineHeight = 30, TextWrapping = TextWrapping.Wrap, Width = 903 };
                SetLive();
                MockFull.Put(canvas, new ScrollViewer { Content = _live, Width = 903, Height = 300, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 234, 404);
            }
            else
            {
                _box.IsEnabled = !Locked;
                MockFull.Put(canvas, _box, 234, 404);
                if (!Locked) DispatcherQueue.TryEnqueue(() => _box.Focus(FocusState.Programmatic));
            }
        }
        _count = null; _send = null;
        if (NeedsReply)
            MockFull.Foot(canvas, _detail.Text("practice_goal"), null, MP.Dark(_busy == "send" ? "正在生成…" : "重新生成", Regenerate, enabled: _busy is null));
        else if (writing)
        {
            var right = new List<UIElement>();
            if (!_listening) right.Add(_count = Sans("", 13, MP.Mute));
            right.Add(VoiceButton());
            right.Add(_send = MP.Dark("发送", Send));
            MockFull.Foot(canvas, _detail.Text("practice_goal"), null, [.. right]);
        }
        else
        {
            var feedback = MockFull.AnswerFeedback(null, _noted);
            MockFull.Foot(canvas, _detail.Text("practice_goal"), null, feedback is null ? Array.Empty<UIElement>() : new UIElement[] { feedback });
        }
        Refresh();
        Content = MockFull.Stage(canvas);
    }

    void Refresh()
    {
        var text = _box.Text;
        if (_count is not null) _count.Text = text.Length == 0 ? "Enter 发送，Shift + Enter 换行" : $"{text.Length} 字";
        if (_send is not null) _send.Enabled = !Locked && !_listening && !_recognizing && text.Trim().Length > 0;
    }

    void SetLive()
    {
        if (_live is null) return;
        _live.Inlines.Clear();
        _live.Inlines.Add(new Run { Text = _box.Text, Foreground = Brush(MP.Ink) });
        _live.Inlines.Add(new Run { Text = _recognizing ? "" : _voice.Partial, Foreground = Brush(MP.Faint) });
    }

    /// <summary>思考界面：题目收起，三个点在闪，刚写的回答留在原处变灰，被记下的原话标蓝色下划线。</summary>
    void Thinking(Canvas canvas, JsonNode? shownQuestion)
    {
        var title = _sent is null ? "好，这题先放下。" : _noted > 0 ? "好，我想想下一个问题。" : "我看一下你的回答。";
        MockFull.Center(canvas, MockSessionText.ThinkingEyebrow(_detail, shownQuestion, _sent is null), 239);
        MockFull.Center(canvas, title, 267, 46, 64, MP.Ink, serif: true);
        MockFull.ThinkDots(canvas);
        if (_sent is { Length: > 0 } sent)
        {
            var block = new TextBlock { FontFamily = SansFamily, FontSize = 17, LineHeight = 30, TextWrapping = TextWrapping.Wrap, MaxLines = 4, Width = 892, TextTrimming = TextTrimming.CharacterEllipsis };
            foreach (var (text, marked) in MockSessionText.QuoteSegments(sent, _quotes))
            {
                if (marked)
                {
                    var underline = new Underline { Foreground = Brush(MP.Ink) };
                    underline.Inlines.Add(new Run { Text = text });
                    block.Inlines.Add(underline);
                }
                else block.Inlines.Add(new Run { Text = text, Foreground = Brush(MP.Mute) });
            }
            MockFull.Put(canvas, block, 234, 404);
        }
    }

    /// <summary>底部「语音输入」：说的话转成文字落进写字区，发送时带上识别会话。</summary>
    FrameworkElement VoiceButton()
    {
        var label = _listening ? "停止" : _recognizing ? "正在识别…" : _voiceFailed ? "没听清，再试一次" : "语音输入";
        var row = HStack(6,
            _listening ? new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 7, Height = 7, Fill = Brush(MP.Blue), VerticalAlignment = VerticalAlignment.Center } : Icon("mic", 12, MP.Fnt),
            Sans(label, 13, _listening ? MP.Blue : MP.Fnt));
        return row.OnTap(() => _ = ToggleVoice(), _listening ? "停止录音" : "语音输入", () => _listening || (!Locked && !_recognizing));
    }

    async Task ToggleVoice()
    {
        if (App.Session.Api is not HttpApiClient client) { MP.Notice("语音输入暂不可用", error: true); return; }
        if (_listening)
        {
            _listening = false; _recognizing = true; Render();
            try
            {
                var result = await _voice.StopAsync(_life.Token);
                var merged = _box.Text + result.Text;
                _box.Text = merged.Length > MaxAnswer ? merged[..MaxAnswer] : merged;
                _speechSession = result.SessionId;
            }
            catch (OperationCanceledException) { return; }
            catch { _voiceFailed = true; }
            _recognizing = false;
            if (_life.Alive) Render();
            return;
        }
        if (Question is not { } question) return;
        _voiceFailed = false; _listening = true; Render();
        try { await _voice.StartAsync(client.Coordinator, _detail.Display("id"), question.Display("id"), "voice_input", null, _life.Token); }
        catch (OperationCanceledException) { }
        catch { _listening = false; _voiceFailed = true; if (_life.Alive) Render(); }
    }

    /// <summary>面试官逐字「打」出来（一次两个字），打完 0.6 秒后回到作答；结束语打完交给结束页。</summary>
    DateTime _typedAt;
    void Type()
    {
        if (_phase is not (Phase.Asking or Phase.Closing)) return;
        if (_shown < _askText.Length)
        {
            _shown = Math.Min(_askText.Length, _shown + 2);
            _typedAt = DateTime.UtcNow;
            if (_question is not null) MockFull.SetQuestion(_question, _askText, _shown);
            return;
        }
        if (_phase == Phase.Asking && _turnReady && (DateTime.UtcNow - _typedAt).TotalMilliseconds >= 600)
        {
            _phase = Phase.Answer; _askText = ""; _shown = int.MaxValue; _turnReady = false;
            Render();
        }
    }

    async Task Consume(string command, JsonObject? body, string? answered, string? sentText)
    {
        _phase = Phase.Sent; _sent = sentText; _turnReady = false; _noted = 0; _quotes = []; _pause(true);
        Render();
        try
        {
            var turn = new MockTurn(await _life.Request(Path(command), "POST", body));
            if (answered is not null && body?["question_id"] is { } id) _detail = MockDetailEdit.Answered(_detail, id.ToString(), answered);
            foreach (var (question, notes) in turn.Notes)
            {
                _detail = MockDetailEdit.WithNotes(_detail, question, notes);
                _noted = notes.Items().Count;
                _quotes = notes.Items().Select(n => n.Text("quote")).Where(q => q.Length > 0).ToList();
            }
            if (turn.Notes.Count > 0) { Render(); await Task.Delay(1200); }
            if (turn.End is null) throw new ApiException(System.Net.HttpStatusCode.BadGateway, "MOCK_INTERVIEW_TURN_FAILED");
            if (turn.Finished)
            {
                _askText = turn.Spoken.NonEmpty() ?? turn.End.Text("closing_message").NonEmpty() ?? "今天的面试就到这里，感谢你的时间。";
                _shown = 0; _phase = Phase.Closing; Render();
                await Task.Delay(2400);
                _pause(false); _changed();
                return;
            }
            _detail = MockDetailEdit.AppendTurn(_detail, turn.End);
            _askText = turn.Spoken.NonEmpty() ?? turn.End.Get("question").Text("content");
            _shown = 0; _phase = Phase.Asking; _sent = null; _turnReady = true;
            Render();
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error)
        {
            MP.Notice(answered is null && sentText is null ? "没能跳过此题" : "回答没有提交成功", MP.Error(error), error: true);
            if (answered is not null) _box.Text = answered;
            _sent = null; _askText = ""; _phase = Phase.Answer;
            Render();
        }
        _pause(false); _changed();
    }

    async void Send()
    {
        var text = _box.Text.Trim();
        if (Question is not { } question || text.Length == 0 || Locked || _listening || _recognizing) return;
        _busy = "send"; _box.Text = "";
        var body = new JsonObject { ["question_id"] = question["id"]?.DeepClone(), ["answer"] = text, ["__idempotency_key"] = MockDetailEdit.Key() };
        if (_speechSession.Length > 0) body["speech_session_id"] = _speechSession;
        _speechSession = "";
        await Consume("answers", body, text, text);
        _busy = null; if (_life.Alive) Render();
    }

    async void Skip()
    {
        if (Question is not { } question) return;
        _busy = "skip";
        await Consume("skip", new JsonObject { ["question_id"] = question["id"]?.DeepClone(), ["__idempotency_key"] = MockDetailEdit.Key() }, null, null);
        _busy = null; if (_life.Alive) Render();
    }

    async void Regenerate()
    {
        var last = _detail.Items("questions").Where(q => q.Text("answer_status") == "answered").OrderByDescending(q => q.Number("sequence_no") ?? 0).FirstOrDefault();
        _busy = "send";
        await Consume("reply:retry", null, null, last.Text("answer_text"));
        _busy = null; if (_life.Alive) Render();
    }

    async void End(string kind)
    {
        _busy = kind; Render();
        try { await _life.Request(Path(kind), "POST"); _voice.Cancel(); _changed(); }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice("操作没有完成", MP.Error(error), error: true); }
        _busy = null; if (_life.Alive) Render();
    }
}
