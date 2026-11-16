using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.Devices.Enumeration;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 语音面试（Windows 稿 09 · 03 开始前、05 面试中 05.01–05.07；Mac `MockVoiceSession`、Web `VoiceSessionV2` + `DeviceCheckStage`）：
/// 准备题目 → 检查设备 → 面试官念题（字幕逐字）→ 开口作答，答完点「说完了」（停顿思考不会被打断，最长 5 分钟自动提交）
/// → 面试官看笔记 → 下一题；没听清时请你再说一遍。录音与识别沿用 `MockVoiceRecorder`，面试官声音沿用 `MockVoicePlayer`。
/// </summary>
internal sealed class MockVoiceSession : UserControl, IMockStage
{
    enum Phase { Prep, Check, Asking, Listening, Submitting, Unclear, SubmitFailed, Closing }
    const string UnclearText = "抱歉，刚才这段没听清，可以再说一遍吗？";
    const double PauseHint = 1.0, SilenceHint = 8.0, MaxRecording = 5.0 * 60, Threshold = 0.06;

    JsonNode _local;
    readonly MockViewLifetime _life;
    readonly Action _changed, _home;
    readonly Action<bool> _pause;
    readonly MockVoiceRecorder _recorder = new();
    readonly MockVoicePlayer _player;
    readonly MockLevels _levels = new();
    MockPrepStage? _prep;
    MockDeviceCheck? _check;
    Phase _phase;
    JsonNode? _question;
    string _askText = "", _transcript = "", _actionKey = "";
    int _shown;
    DateTime _recordStart = DateTime.UtcNow, _lastVoice = DateTime.UtcNow, _typedAt = DateTime.UtcNow;
    bool _heard, _audioFailed, _recordingDropped;
    MockVoiceRecorder.Final? _recognized;
    JsonNode? _feedback;
    int _noted;
    string? _busy;
    TextBlock? _clock, _status, _subtitle, _questionBlock;
    MockLiveWave? _wave;
    Grid? _actionHost;
    StackPanel? _statusRow;

    public MockVoiceSession(JsonNode detail, MockViewLifetime life, Action changed, Action home, Action<bool> pause)
    {
        (_local, _life, _changed, _home, _pause) = (detail, life, changed, home, pause);
        _player = new MockVoicePlayer(DispatcherQueue);
        _player.Failed += () => DispatcherQueue.TryEnqueue(() => { _audioFailed = true; Tick(); });
        _recorder.Changed += () => DispatcherQueue.TryEnqueue(Heard);
        _recorder.Failed += message => DispatcherQueue.TryEnqueue(() =>
        {
            if (_phase != Phase.Listening) return;
            MP.Notice("录音没能继续", message, error: true);
            _shown = 0; _phase = Phase.Unclear; Render();
        });
        Unloaded += (_, _) => { _recorder.Cancel(); _player.Stop(); };
        MockFull.Every(this, TimeSpan.FromMilliseconds(90), Type);
        MockFull.Every(this, TimeSpan.FromMilliseconds(200), Tick);
        _phase = detail.Text("status") == "in_progress" ? Phase.Check : Phase.Prep;
        _question = MockSession.Current(detail);
        Render();
    }

    static Microsoft.UI.Xaml.Media.SolidColorBrush Tone(bool warn) => Brush(warn ? MP.Orange : MP.Sub);
    DrawOffer.Core.Session.SessionCoordinator? Api => (App.Session.Api as HttpApiClient)?.Coordinator;
    string Path(string command) => $"/api/mock-interviews/{_local.Display("id")}/{command}";

    public void Update(JsonNode detail)
    {
        _local = detail;
        if (_phase == Phase.Prep && detail.Text("status") == "in_progress") { _phase = Phase.Check; Render(); return; }
        if (_phase is Phase.Prep or Phase.Check) { _question = MockSession.Current(detail); Render(); }
    }

    void Render()
    {
        switch (_phase)
        {
            case Phase.Prep:
                _check = null;
                if (_prep is null) _prep = new MockPrepStage(_local, _life, _changed, _home, () => { _phase = Phase.Check; Render(); });
                else _prep.Update(_local);
                Content = _prep;
                return;
            case Phase.Check:
                _prep = null;
                if (_check is null) _check = new MockDeviceCheck(_local, _life, Start, AskBack, AskText);
                else _check.Update(_local, _busy);
                Content = _check;
                return;
        }
        _prep = null;
        if (_check is not null) { _check.Stop(); _check = null; }
        Interview();
    }

    // MARK: 作答画面（05.01 面试官在问 / 05.02 轮到你 / 05.03 停顿 / 05.04 看笔记 / 05.05 没听清 / 05.06 提交失败 / 05.07 结束语）

    string Spoken => _phase == Phase.Unclear ? UnclearText : _askText;

    void Interview()
    {
        var shownQuestion = _question ?? (_phase == Phase.Closing ? null : MockSession.LastAsked(_local));
        var intro = shownQuestion is not null && MockSessionText.IsIntro(_local, shownQuestion);
        var questionText = _phase == Phase.Unclear ? shownQuestion.Text("content")
            : _phase is Phase.Asking or Phase.Closing ? Spoken : shownQuestion.Text("content").NonEmpty() ?? Spoken;
        var skipLocked = _busy is not null || _question is null || _phase is Phase.Submitting or Phase.Closing or Phase.Unclear;
        var canvas = MockFull.Canvas();
        _clock = MockFull.Head(canvas, _local, timer: true, back: null,
            MP.Link("跳过此题", () => { if (XamlRoot is not null) MockSessionDialogs.Skip(XamlRoot, Skip); }, enabled: () => !skipLocked),
            MP.Link("放弃", () => { if (XamlRoot is not null) MockSessionDialogs.Abandon(XamlRoot, true, () => End("abandon")); }, enabled: () => _busy is null && _phase != Phase.Closing),
            MP.Ghost("结束并评估", () => { if (XamlRoot is not null) MockSessionDialogs.Finish(XamlRoot, _local, () => End("finish")); }, 38, _busy is null && _phase is not (Phase.Closing or Phase.Submitting)));
        MockFull.Center(canvas, _phase == Phase.Closing ? "面试结束" : MockSessionText.Eyebrow(_local, shownQuestion), 175);
        _questionBlock = MockFull.BigQuestion(canvas, questionText, _phase == Phase.Asking && _shown < Spoken.Length ? _shown : int.MaxValue);
        var talking = _phase is Phase.Asking or Phase.Closing or Phase.Unclear;
        _wave = new MockLiveWave(talking ? MockLiveWave.Tone.Interviewer : _phase == Phase.Listening ? MockLiveWave.Tone.You : _phase == Phase.Submitting ? MockLiveWave.Tone.Rest : MockLiveWave.Tone.Flat);
        MockFull.Put(canvas, _wave, 234, 373);

        _status = Sans("", 14, MP.Sub);
        _statusRow = HStack(12, _status);
        if (_audioFailed && _phase == Phase.Asking)
        {
            _statusRow.Children.Add(Sans("先看字幕作答", 14, MP.Sub));
            _statusRow.Children.Add(MP.Link("重试声音", Replay, 14, blue: true));
        }
        _statusRow.HorizontalAlignment = HorizontalAlignment.Center;
        MockFull.Put(canvas, new Grid { Width = 1120, Height = 22, Children = { _statusRow } }, 124, 499);

        _subtitle = Sans("", 17, MP.Ink).Also(t => { t.Width = 900; t.TextAlignment = TextAlignment.Center; t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxLines = 1; });
        MockFull.Put(canvas, _subtitle, 234, 527);

        _actionHost = new Grid { Width = MockFull.Width };
        _actionKey = "";
        MockFull.Put(canvas, _actionHost, 0, 543);

        var note = _recordingDropped && _phase != Phase.Closing ? ("音视频空间已满，这些回答的录音没有保存；回答和识别文字照常保存", true)
            : intro && _phase == Phase.Asking ? ("面试官说完直接开口，答完点「说完了」；停顿思考不会被打断", false)
            : _phase == Phase.Unclear ? ("没听清不算答错，也不计入追问次数", false) : ((string, bool)?)null;
        if (note is { } n) MockFull.Center(canvas, n.Item1, 696, color: n.Item2 ? MP.Orange : MP.Mute);

        var feedback = MockFull.AnswerFeedback(_feedback, _noted);
        MockFull.Foot(canvas, _local.Text("practice_goal"), null, feedback is null ? Array.Empty<UIElement>() : new UIElement[] { feedback });
        Content = MockFull.Stage(canvas);
        Tick();
    }

    /// <summary>每 0.2 秒：计时、状态行、字幕、底部那颗按钮；作答满 5 分钟自动提交。</summary>
    void Tick()
    {
        if (_phase is Phase.Prep or Phase.Check || _status is null) return;
        if (_clock is not null) _clock.Text = MockSessionText.Elapsed(_local);
        var now = DateTime.UtcNow;
        var recording = _phase == Phase.Listening ? (now - _recordStart).TotalSeconds : 0;
        var silent = _phase == Phase.Listening ? (now - _lastVoice).TotalSeconds : 0;
        var speaking = _heard || _recorder.Partial.Length > 0;
        var pausing = _phase == Phase.Listening && _heard && silent >= PauseHint;
        var silentLong = _phase == Phase.Listening && !speaking && recording >= SilenceHint;
        var follow = (_question ?? MockSession.LastAsked(_local)).Text("kind") == "follow_up";
        var (text, warn) = _phase == Phase.SubmitFailed ? (_recognized is not null ? "这段回答没提交成功，录音和文字都还在" : "面试官的回复没生成，你的回答已经保存", true)
            : _phase == Phase.Submitting ? (_busy == "skip" ? "跳过了这道题" : "面试官在看笔记…", false)
            : _phase == Phase.Unclear ? (UnclearText, false)
            : _phase == Phase.Closing ? ("面试官在说结束语", false)
            : silentLong ? ("还在想吗？可以先说思路；实在不会，点右上角跳过此题", true)
            : pausing ? ($"停顿中 · 想好了接着说 · {MockSession.Mmss(recording)}", false)
            : _phase == Phase.Listening ? ($"轮到你 · {MockSession.Mmss(recording)}", false)
            : (follow ? "面试官在追问" : "面试官在问", false);
        _status.Text = text;
        _status.Foreground = Tone(warn);

        if (_subtitle is not null)
        {
            var live = _recorder.Partial.Length == 0 ? _transcript : _recorder.Partial;
            var sub = _phase is Phase.Listening or Phase.Submitting or Phase.SubmitFailed ? live : "";
            _subtitle.Text = sub.Length > 48 ? "…" + sub[^48..] : sub;
            _subtitle.Foreground = Brush(_phase == Phase.Listening && _recorder.Partial.Length > 0 ? MP.Faint : MP.Ink);
        }
        if (_phase == Phase.Listening)
        {
            _levels.Push(_recorder.Level);
            _wave?.Set(MockLiveWave.Tone.You, _levels.Values);
        }

        var intro = _question is not null && MockSessionText.IsIntro(_local, _question);
        var key = _phase == Phase.Asking && _question is not null && !intro ? "interrupt"
            : _phase == Phase.Listening && speaking ? "done"
            : _phase == Phase.Unclear ? "again"
            : _phase == Phase.SubmitFailed ? "resubmit" : "";
        if (key != _actionKey && _actionHost is not null)
        {
            _actionKey = key;
            _actionHost.Children.Clear();
            FrameworkElement? button = key switch
            {
                "interrupt" => MP.Ghost("打断并作答", BeginAnswer),
                "done" => MP.Dark("说完了", StopAndSubmit).Top(34),
                "again" => MP.Dark("重新回答", BeginAnswer),
                "resubmit" => MP.Dark(_recognized is not null ? "重新提交" : "重新生成", () => { if (_recognized is { } r) Submit(r); else Regenerate(); }).Top(34),
                _ => null,
            };
            if (button is not null) { button.HorizontalAlignment = HorizontalAlignment.Center; button.VerticalAlignment = VerticalAlignment.Top; _actionHost.Children.Add(button); }
        }
        if (_phase == Phase.Listening && recording >= MaxRecording) StopAndSubmit();
    }

    void Heard()
    {
        if (_phase != Phase.Listening) return;
        if (_recorder.Level > Threshold || _recorder.Partial.Length > 0) { _heard = true; _lastVoice = DateTime.UtcNow; }
    }

    // MARK: 流程

    /// <summary>面试官逐字「播报」，念完（且语音播完）0.5 秒后自动开始收音；结束语念完 1.5 秒交给结束页；没听清念完 2.6 秒重新收音。</summary>
    void Type()
    {
        if (_phase is not (Phase.Asking or Phase.Closing or Phase.Unclear)) return;
        var spoken = Spoken;
        if (_shown < spoken.Length)
        {
            _shown++;
            _typedAt = DateTime.UtcNow;
            if (_questionBlock is not null && _phase != Phase.Unclear) MockFull.SetQuestion(_questionBlock, spoken, _shown);
            return;
        }
        if (_player.Playing) { _typedAt = DateTime.UtcNow; return; }
        var waited = (DateTime.UtcNow - _typedAt).TotalSeconds;
        if (_phase == Phase.Unclear) { if (waited >= 2.6) BeginAnswer(); return; }
        if (_phase == Phase.Asking && _question is null) return;
        if (_phase == Phase.Asking && waited >= 0.5) BeginAnswer();
        else if (_phase == Phase.Closing && waited >= 1.5) { _phase = Phase.Submitting; _pause(false); _changed(); }
    }

    void Start()
    {
        _recorder.Cancel(); _player.Stop();
        if (_local.Bool("needs_reply")) { Regenerate(); return; }
        if (MockSession.Current(_local) is { } first) Ask(first);
    }

    void Ask(JsonNode next)
    {
        _question = next; _askText = next.Text("content"); _shown = 0; _audioFailed = false; _phase = Phase.Asking;
        Render();
        _ = Play(next);
    }

    async Task Play(JsonNode question)
    {
        if (Api is not { } api) { _audioFailed = true; return; }
        try
        {
            var audio = await api.MockAudioAsync(Path("speech/playback"), "POST", new JsonObject { ["question_id"] = question["id"]?.DeepClone() }, _life.Token);
            if (_life.Alive && _phase == Phase.Asking) _player.Play(audio);
        }
        catch (OperationCanceledException) { }
        catch { _audioFailed = true; if (_life.Alive) Render(); }
    }

    async void Replay()
    {
        if (_question is null || Api is not { } api) return;
        try { _player.Play(await api.MockAudioAsync(Path("speech/playback"), "POST", new JsonObject { ["question_id"] = _question["id"]?.DeepClone() }, _life.Token)); _audioFailed = false; Render(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { MP.Notice("面试官的声音还是没放出来", MP.Error(error), error: true); }
    }

    async void BeginAnswer()
    {
        if (_question is not { } question || Api is not { } api) return;
        _player.Stop();
        _recognized = null; _transcript = ""; _heard = false; _recordStart = _lastVoice = DateTime.UtcNow; _levels.Clear();
        _phase = Phase.Listening;
        Render();
        try { await _recorder.StartAsync(api, _local.Display("id"), question.Display("id"), "voice_answer", MockDeviceCheck.Device, _life.Token); }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (!_life.Alive || _phase != Phase.Listening) return;
            MP.Notice("录音没能开始", error.Message, error: true);
            _shown = 0; _phase = Phase.Unclear; Render();
        }
    }

    async void StopAndSubmit()
    {
        if (_phase != Phase.Listening) return;
        _phase = Phase.Submitting; Render();
        try
        {
            var result = await _recorder.StopAsync(_life.Token);
            if (result.Text.Trim().Length == 0 || result.SessionId.Length == 0) { _shown = 0; _phase = Phase.Unclear; Render(); return; }
            _recognized = result; _transcript = result.Text;
            Submit(result);
        }
        catch (OperationCanceledException) { }
        catch { if (_life.Alive) { _shown = 0; _phase = Phase.Unclear; Render(); } }
    }

    async void Submit(MockVoiceRecorder.Final result)
    {
        if (_question is not { } question) return;
        _phase = Phase.Submitting; Render();
        try
        {
            await Consume("answers", new JsonObject { ["question_id"] = question["id"]?.DeepClone(), ["speech_session_id"] = result.SessionId, ["__idempotency_key"] = MockDetailEdit.Key() });
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { _phase = Phase.SubmitFailed; Render(); MP.Notice("回答没有提交成功", MP.Error(error), error: true); }
    }

    async void Regenerate()
    {
        _phase = Phase.Submitting; Render();
        try { await Consume("reply:retry", null); }
        catch (OperationCanceledException) { }
        catch (Exception error) { _phase = Phase.SubmitFailed; Render(); MP.Notice("面试官的回复没有生成出来", MP.Error(error), error: true); }
    }

    async void Skip()
    {
        if (_question is not { } question || _busy is not null) return;
        _busy = "skip"; _recorder.Cancel(); _player.Stop(); _transcript = ""; _phase = Phase.Submitting; Render();
        try { await Consume("skip", new JsonObject { ["question_id"] = question["id"]?.DeepClone(), ["__idempotency_key"] = MockDetailEdit.Key() }); }
        catch (OperationCanceledException) { }
        catch (Exception error) { MP.Notice("没有跳过这道题", MP.Error(error), error: true); _busy = null; BeginAnswer(); }
        _busy = null;
    }

    /// <summary>读完一个回合：笔记先到，面试官的话按序念（语音片段随回合返回），最后的 turn 带下一题。</summary>
    async Task Consume(string command, JsonObject? body)
    {
        _pause(true);
        try
        {
            var turn = new MockTurn(await _life.Request(Path(command), "POST", body));
            foreach (var (question, notes) in turn.Notes) { _local = MockDetailEdit.WithNotes(_local, question, notes); _noted = notes.Items().Count; }
            if (turn.AudioFailed) _audioFailed = true;
            if (turn.RecordingDropped) _recordingDropped = true;
            if (turn.Feedback is not null) { _feedback = turn.Feedback; }
            if (turn.End is null) throw new ApiException(System.Net.HttpStatusCode.BadGateway, "MOCK_INTERVIEW_TURN_FAILED");
            if (turn.HasAudio) _player.Enqueue(turn.Events);
            try { if ((await _life.Request($"/api/mock-interviews/{_local.Display("id")}")).Get("mock_interview") is JsonObject fresh) _local = fresh; }
            catch (Exception error) when (error is not OperationCanceledException) { }
            if (turn.Finished)
            {
                _question = null;
                _askText = turn.Spoken.NonEmpty() ?? turn.End.Text("closing_message").NonEmpty() ?? "今天的面试就到这里，感谢你的时间。";
                _shown = 0; _phase = Phase.Closing; Render();
                return;
            }
            var next = turn.End.Get("question")!;
            _question = next; _askText = turn.Spoken.NonEmpty() ?? next.Text("content"); _shown = 0; _phase = Phase.Asking;
            Render();
        }
        finally { if (_phase != Phase.Closing) _pause(false); }
    }

    async void End(string kind)
    {
        _busy = kind; Render();
        try { await _life.Request(Path(kind), "POST"); _recorder.Cancel(); _player.Stop(); _changed(); }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice(kind == "finish" ? "没有结束面试" : "没有放弃面试", MP.Error(error), error: true); }
        _busy = null; if (_life.Alive) Render();
    }

    // MARK: 检查设备阶段：返回修改是放弃本场回首页；改为文字面试沿用同一份题目（`POST answer-mode`）

    void AskBack()
    {
        if (XamlRoot is null) return;
        var preparing = _local.Text("status") == "preparing";
        MP.Confirm(XamlRoot, "返回修改设置？", preparing ? "题目还在准备，返回后这场记为已放弃，不扣积分。" : "返回后这场记为已放弃，改好设置再开始新的一场。",
            "返回改设置", () => Leave("back"), preparing ? "继续准备" : "继续面试");
    }

    void AskText()
    {
        if (XamlRoot is null) return;
        MP.Confirm(XamlRoot, "改为文字面试？", "沿用同一套题目，改成打字作答，也可以语音转文字。", "改为文字面试", () => Leave("text"));
    }

    async void Leave(string target)
    {
        _busy = target; Render();
        try
        {
            if (target == "back")
            {
                if (_local.Text("status") is "preparing" or "preparation_failed" or "in_progress") await _life.Request(Path("abandon"), "POST");
                _home();
            }
            else
            {
                await _life.Request(Path("answer-mode"), "POST", new JsonObject { ["answer_mode"] = "text" });
                _changed();
            }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice("操作没有完成", MP.Error(error), error: true); }
        _busy = null; if (_life.Alive) Render();
    }
}

// MARK: 检查设备（Windows 稿 09 · 03 开始前 03.03 先试一下声音、03.04 这台设备暂时没法语音面试；Mac `MockDeviceCheck`、Web `DeviceCheckStage`）

internal sealed class MockDeviceCheck : UserControl
{
    enum Trial { Idle, Listening, Recognizing, Ok, Empty, Failed }
    enum Speaker { Idle, Playing, Confirm, Heard, Unheard, Unsupported }
    enum Permission { Idle, Granted, Denied, Unavailable }
    const string Phrase = "我准备好了，可以开始了";
    const double Threshold = 0.06;

    /// <summary>这台电脑上选的麦克风；作答时沿用。</summary>
    public static string? Device;

    JsonNode _detail;
    string? _busy;
    readonly MockViewLifetime _life;
    readonly Action _start, _back, _toText;
    readonly MockVoiceRecorder _recorder = new();
    readonly MockVoicePlayer _player;
    readonly MockLevels _levels = new();
    IReadOnlyList<DeviceInformation> _devices = [];
    Permission _permission = Permission.Idle;
    Trial _trial = Trial.Idle;
    Speaker _speaker = Speaker.Idle;
    bool _heardVoice, _quiet;
    DateTime _trialStart, _granted;
    DateTime? _trialVoiceAt;
    MockMiniWave? _wave;

    public MockDeviceCheck(JsonNode detail, MockViewLifetime life, Action start, Action back, Action toText)
    {
        (_detail, _life, _start, _back, _toText) = (detail, life, start, back, toText);
        _player = new MockVoicePlayer(DispatcherQueue);
        _recorder.Changed += () => DispatcherQueue.TryEnqueue(Level);
        _recorder.Failed += _ => DispatcherQueue.TryEnqueue(() => { if (_trial == Trial.Listening) { _trial = Trial.Failed; Render(); } });
        Unloaded += (_, _) => Stop();
        MockFull.Every(this, TimeSpan.FromMilliseconds(200), Watch);
        Render();
        _ = Probe();
    }

    public void Update(JsonNode detail, string? busy) { _detail = detail; _busy = busy; Render(); }
    public void Stop() { _recorder.Cancel(); _player.Stop(); }

    async Task Probe()
    {
        try
        {
            _devices = await MockVoiceRecorder.DevicesAsync();
            if (_devices.Count == 0) { _permission = Permission.Unavailable; Render(); return; }
            if (Device is null || _devices.All(d => d.Id != Device)) Device = _devices[0].Id;
            _permission = Permission.Granted; _granted = DateTime.UtcNow;
            Render();
            BeginTrial();
        }
        catch { _permission = Permission.Unavailable; Render(); }
    }

    void Level()
    {
        var level = _recorder.Level;
        _levels.Push(level);
        _wave?.Set(_levels.Values);
        if (level > Threshold * 1.5) { _heardVoice = true; _quiet = false; }
        if (_trial == Trial.Listening && level > Threshold) _trialVoiceAt = DateTime.UtcNow;
    }

    /// <summary>读完一句并停顿约 1.2 秒结束试读，最长 12 秒；授权后 5 秒都没声音就提示没听到。</summary>
    void Watch()
    {
        var now = DateTime.UtcNow;
        if (_permission == Permission.Granted && !_heardVoice && !_quiet && (now - _granted).TotalSeconds >= 5) { _quiet = true; Render(); }
        if (_trial != Trial.Listening) return;
        if (_trialVoiceAt is { } at && (now - at).TotalSeconds >= 1.2 || (now - _trialStart).TotalSeconds >= 12) _ = FinishTrial();
    }

    async void BeginTrial()
    {
        if (App.Session.Api is not HttpApiClient client) { _trial = Trial.Failed; Render(); return; }
        _recorder.Cancel(); _trialVoiceAt = null; _trialStart = DateTime.UtcNow; _trial = Trial.Listening; Render();
        try { await _recorder.StartAsync(client.Coordinator, _detail.Display("id"), "", "device_check", Device, _life.Token); }
        catch (OperationCanceledException) { }
        catch (UnauthorizedAccessException) { _permission = Permission.Denied; _trial = Trial.Idle; Render(); }
        catch { _trial = Trial.Failed; Render(); }
    }

    async Task FinishTrial()
    {
        _trial = Trial.Recognizing; Render();
        try
        {
            var text = (await _recorder.StopAsync(_life.Token)).Text.Trim();
            _trial = text.Length == 0 ? Trial.Empty : Trial.Ok;
            if (text.Length > 0) { _heardVoice = true; _quiet = false; }
        }
        catch (OperationCanceledException) { return; }
        catch { _trial = Trial.Failed; }
        if (_life.Alive) Render();
    }

    void Recheck()
    {
        _heardVoice = false; _quiet = false; _trial = Trial.Idle; _speaker = Speaker.Idle; _recorder.Cancel(); _permission = Permission.Idle;
        Render();
        _ = Probe();
    }

    async void Preview()
    {
        _player.Stop(); _speaker = Speaker.Playing; Render();
        try
        {
            if (App.Session.Api is not HttpApiClient client) throw new InvalidOperationException();
            _player.Play(await client.Coordinator.MockAudioAsync($"/api/mock-interviews/{_detail.Display("id")}/speech/playback", "POST", new JsonObject(), _life.Token));
            await Task.Delay(300);
            while (_player.Playing) await Task.Delay(200);
            _speaker = Speaker.Confirm;
        }
        catch (OperationCanceledException) { return; }
        catch { _speaker = Speaker.Unsupported; }
        if (_life.Alive) Render();
    }

    void Render()
    {
        var granted = _permission == Permission.Granted;
        var blocked = _permission == Permission.Denied;
        var silent = granted && _quiet && !_heardVoice;
        var micBad = blocked || silent;
        var speakerBad = _speaker == Speaker.Unheard;
        var preparing = _detail.Text("status") == "preparing";
        var ready = granted && _trial == Trial.Ok && !preparing;
        var canvas = MockFull.Canvas();
        MockFull.Head(canvas, _detail, back: (_busy == "back" ? "正在返回…" : "面试设置", _busy is not null, _back));
        MockFull.Center(canvas, "开始前", 175);
        var rows = new StackPanel { Width = 600, Spacing = 20 };
        _wave = null;
        if (_permission == Permission.Unavailable)
        {
            MockFull.Center(canvas, "这台设备暂时没法语音面试", 203, 46, 64, MP.Ink, serif: true);
            MockFull.Center(canvas, $"同一套 {_detail.Integer("question_count")} 道题可以改成打字作答，题目不用重新准备。", 277, 15, 26, MP.Sub);
            rows.Children.Add(Row("没有检测到麦克风", Sans("插上耳机或外接麦克风后再试", 13, MP.Fnt), null, ""));
            rows.Children.Add(Divider(MP.Line));
            rows.Children.Add(Row("系统没有可用的输入设备", Sans("在“设置 › 系统 › 声音 › 输入”里选一个麦克风", 13, MP.Fnt), null, ""));
            MockFull.Put(canvas, rows, 384, 339);
            MockFull.Foot(canvas, _detail.Text("practice_goal"), null,
                MP.Link("重新检测", Recheck),
                MP.Dark(_busy == "text" ? "正在切换…" : "改为文字面试", _toText, enabled: _busy is null));
            Content = MockFull.Stage(canvas);
            return;
        }
        MockFull.Center(canvas, "先试一下声音", 203, 46, 64, MP.Ink, serif: true);
        MockFull.Center(canvas, "安静环境、戴耳机效果更好。", 277, 15, 26, MP.Sub);

        FrameworkElement micSub;
        if (blocked) micSub = Sans("在“设置 › 隐私和安全性 › 麦克风”中允许 DrawOffer，然后重新检测", 13, MP.Orange);
        else
        {
            var name = _devices.FirstOrDefault(d => d.Id == Device)?.Name ?? "默认麦克风";
            var pick = Sans(name + " ⌄", 13, silent ? MP.Orange : MP.Fnt).Also(t => { t.MaxWidth = 240; t.TextTrimming = TextTrimming.CharacterEllipsis; });
            pick.OnTap(() => V3Popover.Menu(pick, 280, _devices.Select(d => (UIElement)new V3MenuRow(d.Name, () =>
            {
                if (Device == d.Id) return;
                Device = d.Id; _heardVoice = false; _quiet = false; _granted = DateTime.UtcNow; BeginTrial();
            }, isChecked: d.Id == Device)).ToArray()), "选择麦克风");
            micSub = pick;
        }
        _wave = granted ? new MockMiniWave() : null;
        rows.Children.Add(Row("麦克风", micSub, blocked ? (false, "没有权限") : silent ? (false, "没听到声音") : granted ? (true, "正常") : null, "正在请求…", _wave));
        rows.Children.Add(Divider(MP.Line));

        var bad = _trial is Trial.Empty or Trial.Failed;
        var trialSub = HStack(12, Sans(bad ? "没听清，靠近麦克风再读一遍" : $"请读：{Phrase}", 13, bad ? MP.Orange : MP.Fnt));
        if (granted && _trial is Trial.Empty or Trial.Failed or Trial.Ok) trialSub.Children.Add(MP.Link("再读一遍", BeginTrial, blue: true));
        rows.Children.Add(Row("读一句话试试", trialSub, !granted ? null : _trial == Trial.Ok ? (true, "识别成功") : bad ? (false, "没听清") : null,
            !granted ? "等麦克风可用" : _trial == Trial.Recognizing ? "正在识别…" : "正在听…"));
        rows.Children.Add(Divider(MP.Line));

        var speakerSub = HStack(12, MP.Link("▶ " + (_speaker == Speaker.Idle ? "试听" : "再听一次"), Preview, enabled: () => _speaker != Speaker.Playing));
        if (speakerBad) speakerSub.Children.Add(Sans("调大音量或换耳机", 13, MP.Orange));
        if (_speaker == Speaker.Unsupported) speakerSub.Children.Add(Sans("面试时可以看字幕作答", 13, MP.Fnt));
        if (_speaker == Speaker.Confirm)
        {
            speakerSub.Children.Add(MP.Link("听得到", () => { _speaker = Speaker.Heard; Render(); }, blue: true));
            speakerSub.Children.Add(MP.Link("听不到", () => { _speaker = Speaker.Unheard; Render(); }));
        }
        rows.Children.Add(Row("面试官声音", speakerSub,
            _speaker == Speaker.Heard ? (true, "听得到") : speakerBad ? (false, "听不到") : _speaker == Speaker.Unsupported ? (false, "没能播放") : null,
            _speaker == Speaker.Confirm ? "听到了吗？" : _speaker == Speaker.Playing ? "正在播放…" : "还没试听"));
        MockFull.Put(canvas, rows, 384, 339);

        var link = MP.Link(_busy == "text" ? "正在切换…" : micBad || speakerBad ? "改为文字面试" : "不方便说话？改为文字面试", _toText, enabled: () => _busy is null);
        UIElement main = micBad || speakerBad
            ? MP.Dark("重新检测", Recheck)
            : MP.Dark(preparing ? "题目还在准备…" : "开始语音面试", () => { Stop(); _start(); }, enabled: ready);
        MockFull.Foot(canvas, _detail.Text("practice_goal"), null, link, main);
        Content = MockFull.Stage(canvas);
    }

    /// <summary>`.mi3-check`：一行 64 高，左边标题 + 一行说明，右边状态（蓝点正常、橙点有问题、灰点等待）。</summary>
    static FrameworkElement Row(string title, FrameworkElement sub, (bool Ok, string Text)? state, string waiting, FrameworkElement? wave = null)
    {
        var grid = new Grid { Width = 600, Height = 64 };
        grid.Children.Add(VStack(4, Label(title, 15, MP.Ink, Medium).Frame(height: 22), sub.Frame(height: 20)));
        if (wave is not null) { wave.HorizontalAlignment = HorizontalAlignment.Left; wave.VerticalAlignment = VerticalAlignment.Top; wave.Margin = new Thickness(280, 24, 0, 0); grid.Children.Add(wave); }
        if (state is not null || waiting.Length > 0)
        {
            var color = state is { } s ? s.Ok ? MP.Blue : MP.Orange : MP.Mute;
            var mark = HStack(8, new Ellipse { Width = 7, Height = 7, Fill = Brush(color), VerticalAlignment = VerticalAlignment.Center }, Label(state?.Text ?? waiting, 13, color, Medium));
            mark.HorizontalAlignment = HorizontalAlignment.Right; mark.VerticalAlignment = VerticalAlignment.Top; mark.Margin = new Thickness(0, 13, 0, 0);
            grid.Children.Add(mark);
        }
        return grid;
    }
}
