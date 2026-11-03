using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

/// <summary>W6：无侧栏的原生全屏场次。所有导航由宿主接管，离开即取消轮询与音频。</summary>
public sealed partial class MockSessionView : UserControl
{
    readonly string _id;
    readonly string? _owner = App.Session.User?.Id;
    readonly Action _home;
    readonly Action<string> _report, _open;
    CancellationTokenSource _life = new();
    readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(40) };
    JsonNode? _detail;
    string _phase = "answer", _draft = "", _speechSession = "", _ask = "", _sent = "", _error = "";
    string? _busy, _device;
    bool _loaded, _disposed, _checking, _deviceReady, _heard, _audioFailed, _recordingDropped, _drawing;
    int _shown = int.MaxValue, _typeTicks;
    DateTimeOffset _lastVoice, _recordStart, _phaseAt;
    JsonNode? _pendingBody;
    string? _pendingCommand;
    string? _pendingQuestion;
    MockVoiceRecorder.Final? _recognized;
    readonly MockVoiceRecorder _recorder = new();
    readonly MockVoicePlayer _player;
    ContentDialog? _activeDialog;
    TextBox? _input;
    TextBlock? _liveText, _statusText, _timerText, _questionText;
    ProgressBar? _meter;
    readonly Grid _host = new();
    readonly List<MockMap.Point> _memory = [];
    readonly List<MockMap.Sector> _sectors = [];
    Func<string?, string?>? _experience;
    string _contextKey = "";
    string Status => S(_detail, "status");
    bool Voice => S(_detail, "answer_mode") == "voice";
    bool Locked => _busy is not null || _phase != "answer" || Question is null || B(_detail, "needs_reply");
    JsonNode? Question => Questions.FirstOrDefault(q => S(q, "id") == S(_detail, "current_question_id") && S(q, "answer_status") == "pending");
    IEnumerable<JsonNode?> Questions => _detail?["questions"] is JsonArray a ? a : Enumerable.Empty<JsonNode?>();
    JsonNode? ShownQuestion => Question ?? Questions.OrderBy(q => N(q, "sequence_no")).LastOrDefault();
    string Path(string command = "") => "/api/mock-interviews/" + _id + (command.Length > 0 ? "/" + command : "");
    internal static string S(JsonNode? node, string key) => node?[key] is JsonValue value ? value.ToString() : "";
    internal static int N(JsonNode? node, string key) => int.TryParse(S(node, key), out var value) ? value : 0;
    internal static bool B(JsonNode? node, string key) => S(node, key) == "true";
    internal static DateTimeOffset? Date(JsonNode? node, string key) => DateTimeOffset.TryParse(S(node, key), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value) ? value : null;
    static string Elapsed(TimeSpan time) => $"{Math.Max(0, (int)time.TotalMinutes):00}:{Math.Max(0, time.Seconds):00}";

    public MockSessionView(string id, Action home, Action<string> report, Action<string> open)
    {
        _id = id; _home = home; _report = report; _open = open;
        _player = new(DispatcherQueue);
        Content = _host; Background = Brush(White);
        _recorder.Changed += () => DispatcherQueue.TryEnqueue(VoiceChanged);
        _recorder.Failed += message => DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed) return;
            _recorder.Cancel();
            if (_checking) { _trialBusy = false; _trialOk = false; _microphoneError = message; }
            else if (!Voice) { _error = message; _phase = "answer"; }
            else { _error = message; _phase = "unclear"; _phaseAt = DateTimeOffset.UtcNow; }
            Render();
        });
        _player.Failed += () => { _audioFailed = true; if (!_disposed) Render(); };
        _clock.Tick += (_, _) => Tick();
        Loaded += async (_, _) =>
        {
            if (_loaded) return;
            _loaded = true; _clock.Start();
            await LoadAsync();
            _ = PollAsync();
        };
        App.Session.PropertyChanged += IdentityChanged;
        Unloaded += (_, _) => { App.Session.PropertyChanged -= IdentityChanged; _disposed = true; _life.Cancel(); _clock.Stop(); _recorder.Dispose(); _player.Dispose(); };
        Render();
    }

    void IdentityChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (_owner == App.Session.User?.Id && App.Session.Phase == DrawOffer.Core.Session.SessionViewModel.SessionPhase.SignedIn) return;
        _life.Cancel(); _recorder.Cancel(); _player.Stop(); _clock.Stop(); _activeDialog?.Hide(); _activeDialog = null;
        _detail = null; _draft = _sent = _speechSession = _ask = ""; _recognized = null; _pendingBody = null; _pendingCommand = null;
        _memory.Clear(); _sectors.Clear(); _experience = null; _error = "登录状态已变化，请返回模拟面试重新进入。";
        if (!_disposed) { Render(); _disposed = true; }
    }

    async Task<JsonNode> Request(string command = "", string method = "GET", JsonNode? body = null)
    {
        var user = App.Session.User?.Id;
        if (user is null) throw new InvalidOperationException("登录已失效，请重新登录。");
        var result = await App.Session.Api.CareerRequestAsync(Path(command), method, body: body?.DeepClone(), ct: _life.Token);
        _life.Token.ThrowIfCancellationRequested();
        if (user != App.Session.User?.Id) throw new OperationCanceledException();
        return result;
    }
    async Task LoadAsync(bool draw = true)
    {
        try
        {
            var result = await Request();
            var fresh = result["mock_interview"] ?? throw new IOException("场次响应无效。");
            var previous = Status;
            _detail = fresh.DeepClone();
            if (Status == "completed" && draw) { _report(_id); return; }
            if (Voice && Status == "in_progress" && (previous != "in_progress" || !_loadedVoice)) { _checking = true; _loadedVoice = true; }
            await LoadContextAsync();
            if (draw) Render();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _error = Error(ex); if (draw) Render(); }
    }
    bool _loadedVoice;
    async Task LoadContextAsync()
    {
        var key = S(_detail, "resume_id") + "|" + S(_detail, "job_description_id");
        if (_contextKey == key) return;
        _contextKey = key;
        try
        {
            var api = App.Session.Api;
            var atlasTask = api.CareerRequestAsync("/api/memory/atlas", ct: _life.Token);
            var outlineTask = api.CareerRequestAsync("/api/memory/outline", query: S(_detail, "job_description_id") is { Length: > 0 } job ? new() { ["job_id"] = job } : null, ct: _life.Token);
            await Task.WhenAll(atlasTask, outlineTask);
            _life.Token.ThrowIfCancellationRequested();
            if (_owner != App.Session.User?.Id) return;
            var model = MockMap.HomePoints(atlasTask.Result, outlineTask.Result, null, S(_detail, "interview_type"));
            _memory.Clear(); _memory.AddRange(model.Points.Select(p => p.Point)); _sectors.Clear(); _sectors.AddRange(model.Sectors);
            if (S(_detail, "resume_id") is { Length: > 0 } resume)
            {
                var doc = await api.CareerRequestAsync("/api/resumes/" + resume, ct: _life.Token);
                _life.Token.ThrowIfCancellationRequested();
                if (_owner == App.Session.User?.Id) _experience = MockMap.ExperienceIndex(doc["resume"]?["data"]);
            }
        }
        catch (OperationCanceledException) { }
        catch { /* Context enriches the map; session actions remain available without it. */ }
    }
    async Task PollAsync()
    {
        try
        {
            while (!_life.IsCancellationRequested)
            {
                await Task.Delay(2500, _life.Token);
                if (_busy is null && _phase != "closing" && Status is "preparing" or "evaluating") await LoadAsync();
            }
        }
        catch (OperationCanceledException) { }
    }
    static string Error(Exception ex) => ex is DrawOffer.Core.Api.ApiException api ? api.Code switch
    {
        "MOCK_INTERVIEW_NOT_FOUND" => "找不到这场模拟面试。",
        "UNAUTHORIZED" => "登录已失效，请重新登录。",
        "MOCK_INTERVIEW_TURN_FAILED" => "面试官暂时没有回复，你的回答可能已经保存，请重新加载后继续。",
        _ => "操作没有完成（" + api.Code + "），请重试。",
    } : ex.Message;

    void Tick()
    {
        if (_disposed) return;
        if (_timerText is not null) _timerText.Text = Elapsed((Date(_detail, "finished_at") ?? DateTimeOffset.UtcNow) - (Date(_detail, "started_at") ?? DateTimeOffset.UtcNow));
        if (_phase is "asking" or "closing")
        {
            if (_shown < _ask.Length)
            {
                if (++_typeTicks % (Voice ? 2 : 1) == 0) _shown = Math.Min(_ask.Length, _shown + (Voice ? 1 : 2));
                if (_questionText is not null) _questionText.Text = _ask[.._shown];
                _phaseAt = DateTimeOffset.UtcNow;
            }
            else if (!_player.Playing && DateTimeOffset.UtcNow - _phaseAt > TimeSpan.FromMilliseconds(_phase == "closing" ? 1500 : 600))
            {
                if (_phase == "closing") { _phase = "answer"; _ = LoadAsync(); }
                else if (Voice) _ = BeginAnswerAsync();
                else { _phase = "answer"; Render(); }
            }
        }
        if (_phase == "unclear" && DateTimeOffset.UtcNow - _phaseAt > TimeSpan.FromSeconds(2.6) && Voice && !_checking) _ = BeginAnswerAsync();
        if (_phase == "listening")
        {
            if (_statusText is not null) _statusText.Text = _heard ? "正在听 · 说完点「说完了」提交" : DateTimeOffset.UtcNow - _recordStart > TimeSpan.FromSeconds(8) ? "还在想吗？可以先说思路，或跳过此题" : VoiceHint;
        }
    }

    async Task RunAsync(string busy, Func<Task> action)
    {
        if (_busy is not null || _disposed || _life.IsCancellationRequested) return;
        _busy = busy; _error = ""; Render();
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _error = Error(ex); }
        finally { _busy = null; if (!_disposed) Render(); }
    }
    async Task ConfirmAsync(string title, string description, string confirm, Func<Task> action)
    {
        if (_busy is not null || _disposed) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = description, PrimaryButtonText = confirm, CloseButtonText = "继续面试", DefaultButton = ContentDialogButton.Close };
        _activeDialog = dialog;
        var response = await dialog.ShowAsync();
        _activeDialog = null;
        if (response == ContentDialogResult.Primary && !_disposed && !_life.IsCancellationRequested) await RunAsync(confirm, action);
    }
    void End(string command) => _ = ConfirmAsync(command == "finish" ? "结束并生成评估？" : "放弃这场面试？", command == "finish" ? Questions.Any(q => S(q, "answer_status") == "answered") ? "已作答的题目会进入评估，后面没问到的题不扣分。" : "你还没有回答任何考点，结束后这场记为已放弃，不生成报告。" : "已作答内容不会生成评估报告。语音录音会删除，放弃后可以重新开始一场。", command == "finish" ? "结束并评估" : "放弃面试", async () =>
    {
        await Request(command, "POST"); _recorder.Cancel(); _player.Stop(); _checking = false; _phase = "answer"; await LoadAsync(false);
    });
    void BackToSettings() => _ = ConfirmAsync("返回修改设置？", "将放弃这场面试，回到模拟面试首页修改设置后重新开始。", "返回改设置", async () => { await Request("abandon", "POST"); _recorder.Cancel(); _home(); });

    async Task SendAsync()
    {
        var text = _draft.Trim();
        if (Locked || text.Length == 0 || _recorder.Recording) return;
        var body = new JsonObject { ["question_id"] = Question?["id"]?.DeepClone(), ["answer"] = text, ["__idempotency_key"] = Guid.NewGuid().ToString() };
        if (_speechSession.Length > 0) body["speech_session_id"] = _speechSession;
        await RunAsync("send", () => ConsumeAsync("answers", body, text));
    }
    void Skip() => _ = ConfirmAsync("跳过这道题？", "跳过的部分记为没答，面试官会换下一个考点；前面已经答的照常评分。", "跳过此题", async () =>
    {
        _recorder.Cancel(); _player.Stop();
        await ConsumeAsync("skip", new JsonObject { ["question_id"] = Question?["id"]?.DeepClone(), ["__idempotency_key"] = Guid.NewGuid().ToString() }, "");
    });
    async Task ConsumeAsync(string command, JsonNode? body, string sent)
    {
        _pendingCommand = command; _pendingBody = body?.DeepClone(); _pendingQuestion = S(body, "question_id");
        _phase = "sent"; _sent = sent; Render();
        try
        {
            var result = await Request(command, "POST", body);
            var events = result["events"] as JsonArray ?? throw new IOException("面试官的回复没有生成。");
            JsonNode? end = null;
            var spoken = "";
            foreach (var e in events)
            {
                var data = e?["data"];
                switch (S(e, "event"))
                {
                    case "interviewer.delta": spoken += S(data, "content"); break;
                    case "interviewer.turn": end = data; break;
                    case "answer.accepted": _recordingDropped |= B(data, "recording_dropped"); break;
                    case "interviewer.audio_failed": _audioFailed = true; break;
                    case "interviewer.notes":
                        var q = Questions.FirstOrDefault(q => S(q, "id") == S(data, "question_id"));
                        if (q is not null) q["notes"] = data?["notes"]?.DeepClone();
                        break;
                }
            }
            if (end is null) throw new IOException("面试官的回复没有生成。你的回答可能已经保存。");
            _pendingBody = null; _pendingCommand = null; _recognized = null; _draft = ""; _speechSession = "";
            if (Voice) _player.Enqueue(events);
            var finished = S(end, "action") == "finish" || end["question"] is null;
            // Refresh persisted notes and answer states, then retain the returned question if a refresh temporarily fails.
            await LoadAsync(false);
            if (!finished && end["question"] is { } next)
            {
                if (_detail?["questions"] is JsonArray questions && !questions.Any(q => S(q, "id") == S(next, "id"))) questions.Add(next.DeepClone());
                if (_detail is not null) { _detail["current_question_id"] = next["id"]?.DeepClone(); _detail["needs_reply"] = false; }
            }
            _ask = spoken.Length > 0 ? spoken : finished ? S(end, "closing_message") : S(end["question"], "content");
            if (finished && _ask.Length == 0) _ask = "今天的面试就到这里，感谢你的时间。";
            _shown = 0; _phase = finished ? "closing" : "asking"; _phaseAt = DateTimeOffset.UtcNow;
        }
        catch
        {
            _phase = "submitFailed";
            // Preserve exact body, speech session and idempotency key until success or an authoritative reload resolves it.
            throw;
        }
    }
    async Task RetryTurnAsync()
    {
        await RunAsync("retryTurn", async () =>
        {
            if (_pendingCommand is not null) await ConsumeAsync(_pendingCommand, _pendingBody?.DeepClone(), _sent);
            else await ConsumeAsync("reply:retry", null, _sent);
        });
    }
}
