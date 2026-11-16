using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 面试复盘（模拟面试这一边，Windows 稿 09 · 10 复盘 10.01–10.09、11 记忆变化状态；Mac `MockReportV2`、Web `mock-interview/v2/ReportV2.tsx`）：
/// 评估报告转成统一结构（`MockRV`）交给总览、单题详情、面试记录三页，再接上模拟面试才有的东西：
/// 回放录音、修改识别稿后重新评分、判得不对、删除录音、练这几题 / 练这一处。
/// </summary>
internal sealed class MockReportView : UserControl
{
    const int MaxReEvaluate = 3;
    readonly string _id;
    readonly Action _home, _records;
    readonly Action<PracticeFocus> _practice;
    readonly Action<string> _open;
    readonly Action<MockPracticePlan> _practicePlan;
    readonly MockViewLifetime _life;
    readonly MockVoicePlayer _player;
    JsonNode? _detail, _context;
    string? _failed, _question, _playing;
    (string? At, bool On) _reading;
    (string Label, string Date, int Days)? _next;
    bool _busy;
    RRMemorySection? _memory;

    public MockReportView(string id, Action home, Action records, Action<PracticeFocus> practice, Action<string> open, Action<MockPracticePlan> practicePlan)
    {
        (_id, _home, _records, _practice, _open, _practicePlan) = (id, home, records, practice, open, practicePlan);
        Background = Brush(V3.White);
        _life = new MockViewLifetime(this, home);
        _player = new MockVoicePlayer(DispatcherQueue);
        Unloaded += (_, _) => _player.Stop();
        Content = new V3Loading("正在打开复盘…").Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Loaded += (_, _) => _ = Load();
    }

    Task<JsonNode> Call(string path, string method = "POST", JsonNode? body = null) => _life.Request($"/api/mock-interviews/{_id}{path}", method, body);

    async Task Load()
    {
        try { _detail = (await Call("", "GET")).Get("mock_interview"); _failed = null; }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { _failed = MP.Error(error); }
        if (!_life.Alive) return;
        Render();
        await LoadContext();
        await LoadNext();
    }

    /// <summary>「和以往比」的数据；拿不到时报告照常，只是不写以往。</summary>
    async Task LoadContext()
    {
        try { _context = await _life.Request("/api/mock-interviews/review-context", "GET", null, new() { ["kind"] = "mock", ["id"] = _id }); }
        catch { return; }
        if (_life.Alive) Render();
    }

    async Task LoadNext()
    {
        var application = _detail.Display("job_application_id");
        if (application.Length == 0) return;
        try
        {
            var now = DateTimeOffset.UtcNow;
            var result = await _life.Request("/api/interview-sessions", "GET", null, new()
            {
                ["status"] = "scheduled", ["start_at"] = now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture), ["application_id"] = application,
            });
            var first = result.Items("items").OrderBy(i => i.Text("start_at"), StringComparer.Ordinal).FirstOrDefault();
            if (first is null || Json.Date(first.Text("start_at")) is not { } date) return;
            _next = (first.Text("stage_label"), date.ToBeijing().ToString("MM-dd", CultureInfo.InvariantCulture), MockMap.DayDiff(now, date));
        }
        catch { return; }
        if (_life.Alive) Render();
    }

    void Render()
    {
        if (_detail is null)
        {
            if (_failed is null) return;
            Content = VStack(10,
                Serif(_failed.Contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来", 22, MP.Ink).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                Sans(_failed, 13, MP.Sub).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                MP.Dark("返回模拟面试", _home).Also(b => b.HorizontalAlignment = HorizontalAlignment.Center).Top(6)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            return;
        }
        if (MockRV.ViewOf(_detail, _context) is not { } view)
        {
            Content = VStack(12, Serif("这场还没有评估报告", 22, MP.Ink).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                MP.Ghost("刷新", () => { _detail = null; Content = new V3Loading("正在打开复盘…").Align(HorizontalAlignment.Center, VerticalAlignment.Center); _ = Load(); }).Also(b => b.HorizontalAlignment = HorizontalAlignment.Center))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            return;
        }
        var detail = _detail;
        var deleted = detail.Bool("recordings_deleted");
        bool HasRecording(MockRV.Question q) => !deleted && q.Turns.Any(t => t.HasRecording);
        bool CanEdit(MockRV.Question q) => !deleted && q.Turns.Any(t => t.Editable);
        var anyRecording = detail.Text("answer_mode") == "voice" && view.Questions.Any(HasRecording);

        if (_reading.On)
        {
            Content = new MockReviewRecord(view, _reading.At, _playing, deleted ? null : Toggle, RRC.Crumb(view.Title, () => { _reading = (null, false); Render(); }));
            return;
        }
        var index = _question is null ? -1 : view.Questions.FindIndex(q => q.Id == _question);
        if (index >= 0)
        {
            var current = view.Questions[index];
            Content = new MockQuestionDetail(current, view.Questions.Count, index > 0 ? view.Questions[index - 1] : null, index + 1 < view.Questions.Count ? view.Questions[index + 1] : null,
                id => { _question = id; Render(); }, q => Start([q], view), q => { _reading = (q.Id, true); Render(); },
                current.Level is not null ? Judge : null, CanEdit(current) ? Edit : null, HasRecording(current) ? Toggle : null, _playing == current.Id,
                RRC.Crumb(view.Title, () => { _question = null; Render(); }));
            return;
        }
        var focus = MockRV.Suggestions(view.Questions);
        UIElement[] actions =
        [
            MP.Ghost("翻看面试记录", () => { _reading = (null, true); Render(); }, 40),
            focus.Count > 0 ? MP.Dark($"练这 {focus.Count} 道", () => Start(focus, view), 40) : MP.Dark(_busy ? "正在准备…" : "再练一次", () => _ = Repeat(), 40, !_busy),
        ];
        _memory ??= new RRMemorySection(detail.Display("id"), view.PastCount, target =>
            _practice(new PracticeFocus(target.Text("kind").NonEmpty() ?? "topic", target.Text("ref"), target.Text("label"))));
        var footnote = anyRecording ? MP.Link("删除本场录音", ConfirmRemove, 12, blue: true) : null;
        Content = new MockReviewOverview(view, _next, id => { _question = id; Render(); }, list => Start(list, view),
            RRC.Crumb("全部记录", _records), actions, _memory, footnote);
    }

    void Start(List<MockRV.Question> questions, MockRV.View view)
    {
        if (questions.Count == 0 || _detail is not { } detail) return;
        _practicePlan(new MockPracticePlan(view.Title, questions.Take(3).Select(MockRV.PracticeItem).ToList(),
            detail.Display("job_application_id").NonEmpty(), detail.Text("interview_type").NonEmpty(), detail.Text("difficulty").NonEmpty(),
            detail.Text("answer_mode").NonEmpty(), detail.Display("resume_id").NonEmpty()));
    }

    static int Remaining(MockRV.Question q) => Math.Max(0, MaxReEvaluate - q.ReEvaluated);

    /// <summary>一题的几轮回答按顺序接着放；再点一下停。</summary>
    async void Toggle(MockRV.Question item)
    {
        if (_playing == item.Id) { _player.Stop(); _playing = null; Render(); return; }
        if (App.Session.Api is not HttpApiClient client || _detail is null) return;
        _player.Stop(); _playing = item.Id; Render();
        try
        {
            foreach (var part in item.Turns.Where(t => t.HasRecording))
            {
                var audio = await client.Coordinator.MockAudioAsync($"/api/mock-interviews/{_detail.Display("id")}/questions/{part.Id}/recording", "GET", null, _life.Token);
                if (_playing != item.Id) return;
                _player.Play(audio);
            }
            while (_player.Playing && _playing == item.Id) await Task.Delay(250, _life.Token);
            if (_playing == item.Id) { _playing = null; Render(); }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { _playing = null; Render(); MP.Notice("这段录音放不了", MP.Error(error), error: true); }
    }

    async Task Repeat()
    {
        _busy = true; Render();
        try { var result = await Call("/repeat"); _busy = false; _open(result.Get("mock_interview").Display("id")); }
        catch (OperationCanceledException) { }
        catch (Exception error) { _busy = false; Render(); MP.Notice("没能再练一次", MP.Error(error), error: true); }
    }

    void Judge(MockRV.Question item)
    {
        if (XamlRoot is null) return;
        MockJudgeDialog.Show(XamlRoot, item, async depth =>
        {
            try
            {
                var result = await Call($"/questions/{item.Id}/judgement", "PUT", new JsonObject { ["user_depth"] = depth is { } d ? JsonValue.Create(d) : null });
                if (result.Get("mock_interview") is JsonObject next) { _detail = next; Render(); }
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { MP.Notice("没有保存", MP.Error(error), error: true); }
        });
    }

    void Edit(MockRV.Question item)
    {
        if (XamlRoot is null) return;
        MockEditDialog.Show(XamlRoot, item, Remaining(item), async drafts =>
        {
            try
            {
                JsonNode? latest = null;
                foreach (var turn in item.Turns.Where(t => t.Editable))
                {
                    if (!drafts.TryGetValue(turn.Id, out var draft) || draft == (turn.Answer ?? "")) continue;
                    latest = (await Call($"/questions/{turn.Id}/transcript", "PUT", new JsonObject { ["text"] = draft })).Get("mock_interview");
                }
                if (latest is null) return;
                _detail = latest;
                if (Remaining(item) > 0)
                {
                    var result = await Call($"/questions/{item.Id}/re-evaluate");
                    if (result.Get("mock_interview") is JsonObject next) _detail = next;
                    MP.Notice("已保存并重新评分这一题", $"还剩 {result.Integer("remaining")} 次 · 不另扣积分");
                }
                Render();
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { MP.Notice("识别稿没有保存", MP.Error(error), error: true); }
        });
    }

    void ConfirmRemove()
    {
        if (XamlRoot is null) return;
        MP.Confirm(XamlRoot, "删除本场录音？", "录音删除后不能恢复，识别文字和评估结果都会保留。", "删除录音", async () =>
        {
            try
            {
                var result = await Call("/recordings", "DELETE");
                if (result.Get("mock_interview") is JsonObject next) _detail = next;
                _player.Stop(); _playing = null; Render();
                MP.Notice("本场录音已删除", "识别文字和评估结果都已保留。");
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { MP.Notice("录音没有删除", MP.Error(error), error: true); }
        });
    }
}
