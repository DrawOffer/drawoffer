using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Devices.Enumeration;
using Windows.System;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.MockSessionChrome;

namespace DrawOffer.App.Views;

public sealed partial class MockSessionView
{
    DrawOffer.Core.Session.SessionCoordinator VoiceApi => (App.Session.Api as DrawOffer.Core.Api.HttpApiClient)?.Coordinator ?? throw new InvalidOperationException("当前会话不支持原生语音。");
    IReadOnlyList<DeviceInformation> _devices = [];
    bool _devicesLoading, _devicesLoaded, _trialBusy, _trialOk;
    bool? _speechAvailable;
    string VoiceHint => _speechAvailable == true ? "直接开口回答 · 说完点「说完了」提交" : "正在检查语音识别能力";
    string _trialText = "", _speakerState = "还没试听", _microphoneError = "";
    TextBlock? _trialDisplay;
    DateTimeOffset _trialAt, _trialVoiceAt;
    string _lastPartial = "";

    void DrawDevice(Canvas frame)
    {
        if (!_devicesLoaded && !_devicesLoading) _ = LoadDevicesAsync();
        var column = VStack(10, Serif("开始前，试一下声音", 30, Ink), Sans($"面试官会用语音提问，你直接开口回答，说完点「说完了」提交。{N(_detail, "question_count")} 题 · 约 {N(_detail, "question_count") * 5} 分钟。", 13, Sub).Wrap());
        var box = new ComboBox { Width = 300, PlaceholderText = "选择麦克风", DisplayMemberPath = "Name", ItemsSource = _devices, SelectedItem = _devices.FirstOrDefault(d => d.Id == _device) };
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is DeviceInformation device && _device != device.Id) { _device = device.Id; _deviceReady = false; _trialOk = false; _recorder.Cancel(); } };
        _meter = new ProgressBar { Minimum = 0, Maximum = 1, Value = _recorder.Level, Width = 150, Height = 10 };
        column.Children.Add(VStack(8, Spread(Sans("麦克风", 14, Ink), Sans(_deviceReady ? "音量正常" : _devicesLoading ? "正在检测…" : _microphoneError.Length > 0 ? "设备不可用" : "等待试读", 12, _deviceReady ? Blue : Muted)), HStack(20, box, _meter), Sans(_microphoneError, 12, Orange).Wrap(), HStack(14, Button("重新检测", () => { _devicesLoaded = false; _trialOk = false; _deviceReady = false; _recorder.Cancel(); Render(); }), Button("系统麦克风设置", () => _ = Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone"))))).Top(24));
        column.Children.Add(Divider(Rule).Top(18));
        _trialDisplay = Sans(_trialOk ? "识别成「" + _trialText + "」" : "请读：「我准备好了，可以开始了」", 12, Sub).Wrap();
        column.Children.Add(VStack(8, Spread(Sans("读一句话试试", 14, Ink), Sans(_trialOk ? "识别正常" : _trialBusy ? "正在听…" : "等麦克风可用", 12, _trialOk ? Blue : Muted)), _trialDisplay, HStack(14, Button(_trialBusy ? "读完了" : _trialOk ? "再读一遍" : "开始试读", () => _ = _trialBusy ? FinishTrialAsync() : BeginTrialAsync(), _busy is null && _devices.Count > 0), Sans("读完停顿约 1.2 秒结束；最长 12 秒", 11, Muted))).Top(18));
        column.Children.Add(Divider(Rule).Top(18));
        column.Children.Add(VStack(8, Spread(Sans("面试官声音", 14, Ink), Sans(_speakerState, 12, _speakerState == "听得到" ? Blue : Muted)), Sans("点试听，确认能听到；播放失败时面试可以看字幕作答", 12, Sub), HStack(14, Button("试听", () => _ = PreviewAsync(), _speakerState != "正在播放…"), Button("听得到", () => { _speakerState = "听得到"; Render(); }), Button("听不到", () => { _speakerState = "听不到，请调大音量或换耳机"; Render(); }))).Top(18));
        column.Children.Add(Divider(Rule).Top(18));
        column.Children.Add(HStack(14, Button(Status == "preparing" ? "题目还在准备…" : "开始语音面试", () => { _checking = false; _recorder.Cancel(); _player.Stop(); if (B(_detail, "needs_reply")) _ = RetryTurnAsync(); else _ = AskInitialAsync(); }, _deviceReady && _trialOk && Status == "in_progress" && _busy is null, true, 40), Button("不方便说话？改为文字面试", SwitchToText, _busy is null)).Top(28));
        column.Children.Add(Sans("安静环境、戴耳机效果更好；回答会保存录音和识别文字，报告里可以对照修正。", 12, Sub).Wrap());
        column.Width = 560; Put(frame, column, 56, 144);
        Put(frame, Button("返回修改", BackToSettings, _busy is null), 36, 776);
    }

    async Task LoadDevicesAsync()
    {
        _devicesLoading = true;
        try
        {
            var capability = await App.Session.Api.CareerRequestAsync("/api/mock-interviews/speech-capability", ct: _life.Token);
            _life.Token.ThrowIfCancellationRequested();
            _speechAvailable = B(capability, "stt");
            _devices = await MockVoiceRecorder.DevicesAsync(); _device ??= _devices.FirstOrDefault()?.Id;
            _microphoneError = _speechAvailable != true ? "语音识别暂未开放，请改为文字面试或稍后重新检测。" : _devices.Count == 0 ? "没有找到麦克风，请连接耳机或外接麦克风后重新检测。" : "";
        }
        catch (Exception ex) { _microphoneError = ex.Message; }
        finally { _devicesLoaded = true; _devicesLoading = false; if (!_disposed) Render(); }
    }
    async Task BeginTrialAsync()
    {
        if (_trialBusy || _speechAvailable != true) return;
        _trialBusy = true; _trialOk = false; _trialText = ""; _trialAt = DateTimeOffset.UtcNow; _trialVoiceAt = DateTimeOffset.MinValue; _microphoneError = ""; Render();
        try
        {
            await _recorder.StartAsync(VoiceApi, _id, "", "device_check", _device, _life.Token);
            _deviceReady = true;
            while (_trialBusy && !_disposed && _recorder.Recording)
            {
                await Task.Delay(200, _life.Token);
                if ((_trialVoiceAt != DateTimeOffset.MinValue && (DateTimeOffset.UtcNow - _trialVoiceAt).TotalSeconds >= 1.2) || (DateTimeOffset.UtcNow - _trialAt).TotalSeconds >= 12) { await FinishTrialAsync(); break; }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _microphoneError = "麦克风没有准备好：" + ex.Message; _trialBusy = false; _recorder.Cancel(); }
        if (!_disposed) Render();
    }
    async Task FinishTrialAsync()
    {
        if (!_trialBusy || !_recorder.Recording) return;
        _trialBusy = false;
        if (_trialDisplay is not null) _trialDisplay.Text = "正在识别…";
        try { var result = await _recorder.StopAsync(_life.Token); _trialText = result.Text.Trim(); _trialOk = _trialText.Length > 0; if (!_trialOk) _microphoneError = "没听清，靠近麦克风再读一遍。"; }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _microphoneError = ex.Message; }
        if (!_disposed) Render();
    }
    async Task PreviewAsync()
    {
        _speakerState = "正在播放…"; Render();
        try
        {
            _player.Stop(); var bytes = await VoiceApi.MockAudioAsync(Path("speech/playback"), "POST", new JsonObject(), _life.Token);
            _life.Token.ThrowIfCancellationRequested(); _player.Play(bytes);
            while (_player.Playing) await Task.Delay(150, _life.Token);
            _speakerState = "听到了吗？";
        }
        catch (OperationCanceledException) { }
        catch { _speakerState = "没能播放，面试时可以看字幕作答"; }
        if (!_disposed) Render();
    }
    void SwitchToText() => _ = ConfirmAsync("改为文字面试？", "沿用同一套题目，只是改成打字作答；输入框里还可以用语音转文字。", "改为文字面试", async () =>
    {
        await Request("answer-mode", "POST", new JsonObject { ["answer_mode"] = "text" });
        _recorder.Cancel(); _player.Stop(); _checking = false; _phase = "answer"; await LoadAsync(false);
    });
    async Task AskInitialAsync()
    {
        _ask = S(Question, "content"); _shown = 0; _phase = "asking"; _phaseAt = DateTimeOffset.UtcNow;
        Render(); await PlayQuestionAsync();
    }
    async Task PlayQuestionAsync()
    {
        var qid = Question?["id"]?.DeepClone();
        if (qid is null) return;
        try
        {
            var data = await VoiceApi.MockAudioAsync(Path("speech/playback"), "POST", new JsonObject { ["question_id"] = qid }, _life.Token);
            _life.Token.ThrowIfCancellationRequested();
            if (_phase == "asking" && S(Question, "id") == qid.ToString()) { _player.Play(data); _audioFailed = false; }
        }
        catch (OperationCanceledException) { }
        catch { _audioFailed = true; }
        if (!_disposed) Render();
    }
    async Task BeginAnswerAsync()
    {
        if (_disposed || _busy is not null || _phase == "listening" || Question is null) return;
        _player.Stop(); _recognized = null; _sent = ""; _heard = false; _lastPartial = "";
        _phase = "connecting"; Render();
        try
        {
            await _recorder.StartAsync(VoiceApi, _id, S(Question, "id"), "voice_answer", _device, _life.Token);
            _life.Token.ThrowIfCancellationRequested();
            _recordStart = _lastVoice = DateTimeOffset.UtcNow; _phase = "listening";
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _error = ex.Message; _phase = "unclear"; _phaseAt = DateTimeOffset.UtcNow; }
        if (!_disposed) Render();
    }
    void VoiceChanged()
    {
        if (_disposed) return;
        if (_meter is not null) _meter.Value = _recorder.Level;
        if (_checking)
        {
            if (_recorder.Level > .06) _trialVoiceAt = DateTimeOffset.UtcNow;
            if (_trialDisplay is not null && _recorder.Partial.Length > 0) _trialDisplay.Text = "请读：「我准备好了，可以开始了」 → " + _recorder.Partial;
            return;
        }
        if (_phase == "listening" && (_recorder.Level > .08 || _lastPartial != _recorder.Partial && _recorder.Partial.Length > 0))
        { _heard = true; _lastVoice = DateTimeOffset.UtcNow; }
        _lastPartial = _recorder.Partial;
        if (_liveText is not null) _liveText.Text = _recorder.Partial;
    }
    void DrawVoiceAnswer(StackPanel column)
    {
        if (_phase == "asking")
        {
            column.Children.Add(VStack(10, Sans("第一次语音面试", 11, Muted), Sans("1  面试官说完，直接开口就行", 13, Sub), Sans("2  说完点「说完了」，提交服务端识别稿", 13, Sub), Sans("3  可以点「打断并作答」提前开始", 13, Sub)).Top(26));
            return;
        }
        if (_phase == "unclear")
        {
            column.Children.Add(Sans("抱歉，刚才这段没听清，可以再说一遍吗？", 23, Ink).Wrap().Top(24));
            column.Children.Add(Sans("没听清不算答错，也不计入追问次数", 12, Muted).Top(10));
            column.Children.Add(Button("重新录音", () => _ = BeginAnswerAsync()).Top(12));
            return;
        }
        column.Children.Add(Sans("你 · " + (_phase == "connecting" ? "正在连接麦克风…" : "正在回答"), 10.5, Orange).Top(34));
        _liveText = Sans(_recorder.Partial.Length > 0 ? _recorder.Partial : "……", 15, Ink).Wrap().LineHeight(28);
        column.Children.Add(Scroll(_liveText, 652, 160).Top(10));
        _meter = new ProgressBar { Minimum = 0, Maximum = 1, Value = _recorder.Level, Width = 300, Height = 5, HorizontalAlignment = HorizontalAlignment.Left };
        column.Children.Add(_meter.Top(16));
        column.Children.Add(Sans("识别稿以服务端结果为准，完成后可在报告里修正。", 11.5, Muted).Top(14));
    }
    async Task StopVoiceAnswerAsync()
    {
        if (_phase != "listening" || !_recorder.Recording) return;
        _phase = "recognizing"; Render();
        try
        {
            var result = await _recorder.StopAsync(_life.Token);
            if (result.Text.Trim().Length == 0 || result.SessionId.Length == 0) { _phase = "unclear"; _phaseAt = DateTimeOffset.UtcNow; Render(); return; }
            _recognized = result; _sent = result.Text;
            await RunAsync("sendVoice", () => ConsumeAsync("answers", new JsonObject { ["question_id"] = Question?["id"]?.DeepClone(), ["speech_session_id"] = result.SessionId, ["__idempotency_key"] = Guid.NewGuid().ToString() }, result.Text));
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _error = ex.Message; if (_pendingCommand is not null) _phase = "submitFailed"; else { _phase = "unclear"; _phaseAt = DateTimeOffset.UtcNow; } }
        if (!_disposed) Render();
    }
    async Task ToggleVoiceInputAsync()
    {
        if (_busy is not null || Question is null) return;
        if (_recorder.Recording)
        {
            await RunAsync("transcribe", async () => { var result = await _recorder.StopAsync(_life.Token); _draft = (_draft + result.Text)[..Math.Min(8000, _draft.Length + result.Text.Length)]; _speechSession = result.SessionId; });
        }
        else
        {
            await RunAsync("microphone", () => _recorder.StartAsync(VoiceApi, _id, S(Question, "id"), "voice_input", null, _life.Token));
        }
    }
}
