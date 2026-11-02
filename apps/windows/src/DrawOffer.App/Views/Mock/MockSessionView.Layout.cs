using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.MockSessionChrome;

namespace DrawOffer.App.Views;

public sealed partial class MockSessionView
{
    void Render()
    {
        if (_disposed || _drawing) return;
        _drawing = true;
        try
        {
            var frame = Frame(); _input = null; _liveText = null; _statusText = null; _questionText = null; _meter = null;
            _host.Children.Clear(); _host.Children.Add(new Viewbox { Child = frame, Stretch = Stretch.Uniform });
            if (_detail is null)
            {
                Put(frame, VStack(16, Serif(_error.Length > 0 ? "模拟面试没有加载出来" : "正在加载模拟面试…", 24), Sans(_error, 13, Sub).Wrap(), Button("重新加载", () => _ = LoadAsync()), Button("返回模拟面试", _home)), 420, 280); return;
            }
            var active = (Status == "in_progress" || _phase == "closing") && !_checking;
            var center = _checking ? "检查设备" : Status is "preparing" or "preparation_failed" ? "准备题目" : active ? MockSession.Progress(_detail, ShownQuestion) : Status == "abandoned" ? "已放弃" : Status == "evaluation_failed" ? "评估没完成" : "已结束";
            var mapPhase = _phase == "sent" ? MockSession.Phase.Thinking : _phase == "closing" || !active ? MockSession.Phase.Done : _phase == "listening" || _draft.Length > 0 ? MockSession.Phase.Answering : MockSession.Phase.Asking;
            var map = MockSession.MapOf(_detail, _memory, _sectors, _experience, ShownQuestion, mapPhase);
            Map(frame, map, MockMap.DiffLevel.GetValueOrDefault(S(_detail, "difficulty"), 3), active, Status == "abandoned");
            Horizon(frame, _detail, ShownQuestion, Status is "evaluating" or "evaluation_failed" or "abandoned" || _phase == "closing");
            _timerText = Number("00:00", 12, Sub);
            Top(frame, new(_detail), center, _timerText, () => End("abandon"), () => End("finish"), _home, active, _busy is null && _phase is not "sent" and not "closing");
            if (_checking) DrawDevice(frame);
            else if (Status is "preparing" or "preparation_failed") DrawPreparation(frame);
            else if (active) DrawAnswer(frame);
            else DrawClosing(frame, map);
            if (_error.Length > 0) Put(frame, Card(Sans(_error, 12, Orange).Wrap(), 8, new Thickness(16), White, Orange).Frame(600), 56, 736);
        }
        finally { _drawing = false; }
    }

    void DrawPreparation(Canvas frame)
    {
        var failed = Status == "preparation_failed";
        var elapsed = Math.Max(0, (DateTimeOffset.UtcNow - (Date(_detail, "created_at") ?? DateTimeOffset.UtcNow)).TotalSeconds);
        var failedStep = S(_detail, "failed_stage") switch { "analysis" => 0, "opening" => 2, _ => 1 };
        var step = failed ? failedStep : elapsed < 9 ? 0 : elapsed < 24 ? 1 : 2;
        var count = N(_detail, "question_count");
        var column = VStack(8, Serif(failed ? "面试官没能准备好题目" : "面试官在读你的简历", 30, Ink), Sans(failed ? "模型服务暂时没有响应，这一次没有扣积分。" : "通常 20–40 秒。可以先离开页面，准备好了会提醒你。", 13, Sub).Wrap());
        var steps = new[] { ("分析简历与岗位背景", "读了 简历「" + S(_detail, "resume_title") + "」" + (S(_detail, "company_name").Length > 0 ? " · " + S(_detail, "company_name") + " JD" : "") + (_memory.Count > 0 ? $" · 长期记忆 {_memory.Count} 个点" : "")), ("制定考察计划", $"已挑 {Math.Clamp(1 + (int)((elapsed - 9) / 3), 0, count)} / {count} 个点：按离目标线的远近排"), ("生成第一道问题", "") };
        var list = VStack(0);
        for (var i = 0; i < steps.Length; i++)
        {
            var symbol = i < step ? "✓" : i == step ? failed ? "!" : "◌" : "○";
            var row = HStack(12, Sans(symbol, 16, failed && i == step ? Orange : i <= step ? Blue : Muted), VStack(4, Sans(steps[i].Item1, 14, i > step ? Muted : Ink), Sans(i > step ? "" : failed ? i == step ? "没有完成 · " + S(_detail, "error_code") : "已完成" : steps[i].Item2, 12, Sub).Wrap()));
            row.MinHeight = 64; list.Children.Add(row);
        }
        column.Children.Add(list.Top(26));
        if (failed) column.Children.Add(HStack(14, Button("重新准备", () => _ = RunAsync("retry", async () => { await Request("retry", "POST"); await LoadAsync(false); }), _busy is null, true, 40), Button("返回改设置", BackToSettings, _busy is null)));
        else if (Voice) column.Children.Add(Card(Spread(VStack(4, Sans("趁现在先试一下麦克风", 13.5, Ink), Sans("试完回来，题目也差不多准备好了", 12, Sub)), Button("去试一下", () => { _checking = true; Render(); })), 8, new Thickness(16), BlueSoft).Top(24));
        column.Width = 560; Put(frame, column, 56, 182);
        Put(frame, Button("返回改设置", BackToSettings, _busy is null), 1160, 776);
    }

    void DrawClosing(Canvas frame, MockSession.Map map)
    {
        var failed = Status == "evaluation_failed"; var abandoned = Status == "abandoned";
        var column = VStack(10, Serif(abandoned ? "这场模拟面试已放弃" : failed ? "评估报告没能生成" : "面试结束，辛苦了", 30, Ink), Sans(abandoned ? "没有生成报告" + (Voice ? "，录音已删除。" : "。") : failed ? "作答" + (Voice ? "和录音" : "") + "都保存了，重新评估不另扣积分。" : "面试官在把笔记整理成评估报告。", 13, Sub).Wrap());
        if (abandoned) column.Children.Add(HStack(14, Button("用同样设置重新开始", () => _ = RunAsync("repeat", async () => { var next = await Request("repeat", "POST"); var id = S(next["mock_interview"], "id"); if (id.Length > 0) _open(id); }), _busy is null, true, 40), Button("返回模拟面试", _home)).Top(28));
        else if (failed) column.Children.Add(HStack(14, Button("重新评估", () => _ = RunAsync("retry", async () => { await Request("retry", "POST"); await LoadAsync(false); }), _busy is null, true, 40), Button("返回模拟面试", _home)).Top(28));
        else
        {
            column.Children.Add(Sans("◌ 正在整理报告 · 约 1 分钟", 12, Muted).Top(36));
            column.Children.Add(HStack(70, Stat(map.Rounds.Count.ToString(), "主问题"), Stat(Questions.Count(q => S(q, "kind") == "follow_up").ToString(), "次追问"), Stat(map.Rounds.Sum(r => MockSession.Notes(r).Count).ToString(), "条要点")).Top(28));
            column.Children.Add(Button("先去忙，好了提醒我", _home).Top(30));
            column.Children.Add(Sans("报告好了会出现在模拟面试首页的地平线上", 13, Sub));
        }
        column.Width = 650; Put(frame, column, 56, 182);
    }
    static StackPanel Stat(string value, string title) => VStack(6, Number(value, 26, Ink), Sans(title, 11.5, Muted));

    void DrawAnswer(Canvas frame)
    {
        var question = ShownQuestion;
        var follow = S(question, "kind") == "follow_up";
        var intro = question is not null && MockMap.IsIntro(_detail, question);
        var column = VStack(0);
        if (MockSession.SourceChip(question) is { } chip) column.Children.Add(Card(VStack(5, Sans(chip.Label, 11, Blue), Sans(chip.Quote, 12, Sub).Wrap(2)), 6, new Thickness(12), BlueSoft, Clear).Top(0));
        var speaker = _phase == "closing" ? "结束语" : _phase == "sent" ? "在想下一句" : _phase == "listening" ? "在听" : follow ? "追问" : intro ? "正在说" : "提问";
        column.Children.Add(Sans("面试官 · " + speaker, 10.5, Muted).Top(14));
        var text = _phase is "asking" or "closing" ? _ask[..Math.Min(_shown, _ask.Length)] : S(question, "content");
        _questionText = Sans(text, Voice ? 23 : 22, Ink).Wrap().LineHeight(34);
        column.Children.Add(_questionText.Top(10));
        if (follow && S(question, "source_quote").Length > 0) column.Children.Add(Sans("↳ 追问来自你刚才的原话：「" + S(question, "source_quote") + "」", 11.5, Blue).Wrap().Top(10));
        if (_audioFailed && Voice) column.Children.Add(HStack(12, Sans("面试官的声音没放出来，先看字幕作答", 11.5, Orange), Button("重试声音", () => _ = PlayQuestionAsync())).Top(10));
        if (_recordingDropped) column.Children.Add(Sans("音视频空间已满，这些回答的录音没有保存；回答和识别文字照常保存", 11, Orange).Wrap().Top(10));
        if (_phase == "submitFailed" || B(_detail, "needs_reply"))
        {
            column.Children.Add(Sans("你 · 已发送", 10.5, Muted).Top(30));
            column.Children.Add(Scroll(Sans(_sent.Length > 0 ? _sent : Questions.LastOrDefault(q => S(q, "answer_status") == "answered") is { } last ? S(last, "answer_text") : "", 15, Sub).Wrap().LineHeight(28), 652, 112).Top(10));
            column.Children.Add(VStack(8, Sans(_pendingCommand is not null ? "这段回答没提交成功" : "面试官的回复没生成", 14, Orange), Sans("你的文字与识别稿保留了，重试不会重复计入。", 12, Sub), Button(_pendingCommand is not null ? "重新提交" : "重新生成", () => _ = RetryTurnAsync(), _busy is null)).Top(20));
        }
        else if (_phase == "sent")
        {
            column.Children.Add(Sans(_sent.Length == 0 ? "你 · 跳过了这道题" : "你 · 已发送", 10.5, Muted).Top(30));
            column.Children.Add(Scroll(Sans(_sent, 15, Sub).Wrap().LineHeight(28), 652, 150).Top(10));
        }
        else if (Voice) DrawVoiceAnswer(column);
        else if (_phase == "answer")
        {
            column.Children.Add(Sans("你 的 回 答", 10.5, Muted).Top(34));
            var input = new TextBox { Text = _draft, PlaceholderText = "输入你的回答…", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxLength = 8000, Height = 155, Width = 652, FontSize = 15, FontFamily = SansFamily, Foreground = Brush(Ink), Background = Brush(Clear), BorderThickness = new Thickness(0), Padding = new Thickness(0, 8, 0, 8), IsEnabled = !Locked && !_recorder.Recording };
            _input = input;
            input.TextChanged += (_, _) => { _draft = input.Text; if (_sendButton is not null) _sendButton.Enabled = !Locked && _draft.Trim().Length > 0 && !_recorder.Recording; };
            input.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter && !Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) { e.Handled = true; _ = SendAsync(); } else if (e.Key == VirtualKey.Escape && _recorder.Recording) { _recorder.Cancel(); Render(); } };
            column.Children.Add(input.Top(10));
            column.Children.Add(Divider(Ink).Frame(652));
            _sendButton = Button("发送", () => _ = SendAsync(), !Locked && _draft.Trim().Length > 0 && !_recorder.Recording, true);
            var tools = Spread(Button(_recorder.Recording ? "正在听 · 再点一下停止" : "语音输入", () => _ = ToggleVoiceInputAsync(), _busy is null), HStack(14, Sans($"{_draft.Length} 字 · Enter 发送，Shift + Enter 换行", 11, Muted), _sendButton));
            tools.Width = 652; column.Children.Add(tools.Top(10));
            if (_recorder.Recording) { _liveText = Sans(_recorder.Partial, 12, Blue).Wrap(); column.Children.Add(_liveText.Top(8)); }
        }
        if (!intro && _phase is not "answer" and not "listening") column.Children.Add(Notes(MockSession.Notes(MockSession.RoundOf(_detail, question))).Top(24));
        column.Width = 680;
        Put(frame, Scroll(column, 700, 526), 56, 96);
        if (_phase != "closing")
        {
            Put(frame, Button("跳过此题", Skip, _busy is null && ((!Locked && !_recorder.Recording) || Voice && _phase is "asking" or "listening")), 36, 776);
            _statusText = Sans(_phase == "sent" ? "等面试官回复" : _phase == "asking" ? "面试官在提问" : _phase == "submitFailed" ? "这段回答还没提交" : Voice ? "直接开口就能答 · 说完点「说完了」提交" : "打字作答，发送前可以修改", 12, Sub);
            Put(frame, _statusText, 390, 785);
            if (Voice && _phase == "listening") Put(frame, Button("说完了", () => _ = StopVoiceAnswerAsync(), _recorder.Recording), 960, 776);
            else if (Voice && _phase == "asking") Put(frame, Button("打断并作答", () => _ = BeginAnswerAsync()), 960, 776);
            Put(frame, Button("对话记录", ShowConversation), 1220, 776);
        }
    }
    V3Button? _sendButton;
    async void ShowConversation()
    {
        var list = VStack(20);
        foreach (var q in Questions.OrderBy(q => N(q, "sequence_no"))) list.Children.Add(VStack(8, Sans(S(q, "kind") == "follow_up" ? "面试官 · 追问" : "面试官 · 提问", 11, Muted), Sans(S(q, "content"), 16, Ink).Wrap(), Sans(S(q, "answer_status") == "skipped" ? "你 · 跳过了这道题" : "你 · " + S(q, "answer_text"), 14, Sub).Wrap().LineHeight(26)));
        var drawer = new ContentDialog { XamlRoot = XamlRoot, Title = "对话记录", Content = Scroll(list, 580, 550), CloseButtonText = "关闭" };
        if (_disposed) return;
        _activeDialog = drawer;
        await drawer.ShowAsync();
        _activeDialog = null;
    }
}
