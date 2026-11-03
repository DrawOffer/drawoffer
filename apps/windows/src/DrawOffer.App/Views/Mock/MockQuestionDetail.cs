using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Mock.MockReportData;

namespace DrawOffer.App.Views.Mock;

/// <summary>Mac MockQuestionDetail: round transcripts, recordings, corrections and per-question evaluation.</summary>
public sealed class MockQuestionDetail : UserControl
{
    JsonNode _detail; Row _row;
    readonly Action<string?> _open; readonly Action _home; readonly Action<Row> _focus; readonly Action<JsonNode> _updated; readonly Action<string> _toast;
    readonly StackPanel _body = new(); readonly Dictionary<string,string> _drafts = [];
    MockViewLifetime? _life; string? _busy, _notice, _playing; bool _editing, _raw;
    MediaPlayer? _player; InMemoryRandomAccessStream? _audio; int _playGeneration;
    readonly Dictionary<string, Slider> _audioSliders = [];
    DispatcherTimer? _audioTimer; V3Overlay? _leaveDialog;
    string Base => "/api/mock-interviews/" + _detail.Display("id");
    int Remaining => Math.Max(0, 3 - _row.Main.Integer("re_evaluate_count"));
    List<JsonNode> Editable => _row.Turns.Where(t => t.Text("answer_source") == "voice" && t.Text("answer_status") == "answered").ToList();
    internal MockQuestionDetail(JsonNode interview, Row row, Action<string?> open, Action home, Action<Row> focus, Action<JsonNode> updated, Action<string> toast)
    {
        (_detail, _row, _open, _home, _focus, _updated, _toast) = (interview, row, open, home, focus, updated, toast);
        Content = new V3Page(_body, 52, 48); Background = Brush(White);
        Loaded += (_, _) => { _life = new(this, () => { StopAudio(); _leaveDialog?.Close(); _drafts.Clear(); _detail = new JsonObject(); _body.Children.Clear(); _body.Children.Add(Sans("登录状态已变化，请返回模拟面试。", 14)); }); Render(); };
        Unloaded += (_, _) => { StopAudio(); _leaveDialog?.Close(); };
        Render();
    }
    public static void Show(XamlRoot root, JsonNode interview, JsonNode evaluation, Action changed)
    {
        var rows = Rows(interview); var row = rows.FirstOrDefault(r => r.Main.Number("sequence_no") == evaluation.Number("sequence_no")) ?? rows.FirstOrDefault(); if (row is null) return;
        V3Overlay.Show(root, close =>
        {
            var host = new Border { Width = 1152, Height = Math.Max(360, root.Size.Height - 48) };
            void Select(string? id)
            {
                if (id is null) { close(); return; }
                var next = Rows(interview).FirstOrDefault(r => r.Id == id); if (next is not null) host.Child = Build(next);
            }
            MockQuestionDetail Build(Row selected) => new(interview, selected, Select, close, _ => close(), updated => { interview = updated; changed(); }, _ => { });
            host.Child = Build(row); return V3Dialog.Frame(host, 1152);
        });
    }
    void Render()
    {
        _audioSliders.Clear(); _body.Children.Clear(); var rows = Rows(_detail); var index = rows.FindIndex(r => r.Id == _row.Id); var target = Target(_detail); var evaluation = _row.Evaluation;
        var skipped = evaluation.Bool("skipped"); var tag = _row.Level == 0 ? skipped ? "跳过了" : $"追问到「{Level(_row.Probed)}」没答上" : _row.Probed > _row.Level ? $"追问到「{Level(_row.Probed)}」 · 答到「{Level(_row.Level)}」" : $"答到「{Level(_row.Level)}」";
        var nav = HStack(6); foreach (var r in rows) nav.Children.Add(new V3Button($"Q{r.No}", () => Navigate(r.Id), r.Id == _row.Id ? V3Button.Kind.Dark : V3Button.Kind.Ghost, height: 28) { Enabled = _busy is null }); nav.Children.Add(new V3Button("×", () => Navigate(null), V3Button.Kind.Text).Tip("回到报告"));
        _body.Children.Add(Spread(HStack(12, LinkButton("← 模拟面试", () => NavigateHome()), Sans("/", 16, Fnt), LinkButton("评估报告", () => Navigate(null)), Sans($"/ 第 {_row.No} 题", 16, Fnt)), nav));
        _body.Children.Add(Serif($"Q{_row.No}  {_row.Topic}", 26).Wrap().Top(12));
        var corrected = _row.Turns.Where(t => t.Text("transcript_state") == "corrected").Sum(t => t.Get("correction").Items("changes").Count);
        var chips = HStack(10, V3Chip.Make(tag, _row.Level >= target ? Blue : Orange, _row.Level >= target ? BlueSoft : OrangeSoft), V3Chip.Make($"追问 {_row.Turns.Count - 1} 次"));
        if (corrected > 0) chips.Children.Add(V3Chip.Make($"AI 已修正 {corrected} 处识别 · 已自动应用", Blue, BlueSoft));
        if (_row.Turns.Any(t => t.Text("answer_source") == "voice") && corrected == 0 && _detail.Text("transcript_corrected_at").Length == 0)
            chips.Children.Add(new V3Button(_busy == "correct" ? "正在修正识别…" : "让 AI 修正识别", () => _ = Correct(), V3Button.Kind.Text) { Enabled = _busy is null && !_editing });
        _body.Children.Add(chips.Top(8)); if (_notice is not null) _body.Children.Add(Paragraph(_notice, 12, Red).Top(12));
        var left = new StackPanel { Spacing = 18 };
        foreach (var (turn, position) in _row.Turns.Select((t, i) => (t, i))) left.Children.Add(Turn(turn, position));
        if (evaluation.Items("signals").FirstOrDefault(s => s.Text("verdict") == "not_probed") is {} notProbed && _row.Probed < 5)
            left.Children.Add(VStack(12, V3Chip.Make($"没问到 · 第 {(int)Math.Min(5, _row.Probed + 1)} 层 · {Level(Math.Min(5, _row.Probed + 1))}"), Line("面试官", $"面试官原本想接着问：「{notProbed.Text("signal")}」", true, true), Divider()));
        if (_editing)
        {
            left.Children.Add(HStack(10, new V3Button(_busy == "save" ? "正在保存…" : Remaining > 0 ? "保存并重新评估" : "保存", () => _ = Save(), V3Button.Kind.Dark) { Enabled = _busy is null }, new V3Button("取消", () => { _editing = false; _drafts.Clear(); Render(); }, V3Button.Kind.Text) { Enabled = _busy is null }));
            left.Children.Add(Sans(Remaining > 0 ? $"重新评估这一题还剩 {Remaining} 次 · 不另扣积分" : "这一题的重新评估次数已用完，保存后只更新文字", 11, Fnt).Wrap());
        }
        else
        {
            var buttons = HStack(10); if (Editable.Count > 0 && !_detail.Bool("recordings_deleted")) buttons.Children.Add(new V3Button("手动修改", () => { _editing = true; Render(); }) { Enabled = _busy is null });
            if (_row.Turns.Any(t => t.Text("raw_transcript").Length > 0)) buttons.Children.Add(new V3Button(_raw ? "看修正后的识别稿" : "查看原始识别稿", () => { _raw = !_raw; Render(); }));
            left.Children.Add(buttons);
            if (index > 0) left.Children.Add(LinkButton("‹ 上一题", () => Navigate(rows[index - 1].Id)));
        }
        var right = new StackPanel { Spacing = 18 };
        var score = VStack(8, HStack(4, Number(evaluation.Number("score")?.ToString("F0") ?? "—", 40), Sans("/ 100", 11.5, Fnt)), LinkButton("设为下次先问 ›", () => Leave(() => _focus(_row))));
        var history = _row.Main.Items("evaluation_history"); if (history.Count > 1) score.Children.Add(Sans($"修正识别后重新评估：{history.First().Number("score"):F0} → {history.Last().Number("score"):F0}", 11, Blue).Wrap());
        if (_editing) score.Children.Add(Sans("改完重新评估后分数会更新", 11, Fnt).Wrap());
        right.Children.Add(Columns(20, (Star(1.2), VStack(4, MockReportView.Map(rows, target, Navigate, 280, 290, _row.Id), Sans("在这场的图上", 10.5, Fnt))), (Star(), score)));
        right.Children.Add(Sans("面试官怎么批的", 13, Txt, Medium));
        foreach (var signal in evaluation.Items("signals").Where(s => s.Text("verdict") != "not_probed"))
        {
            var verdict = signal.Text("verdict"); var color = verdict == "hit" ? Blue : verdict == "partial" ? Orange : Fnt;
            right.Children.Add(Columns(4, (Px(20), Sans(verdict == "hit" ? "✓" : verdict == "partial" ? "◐" : "—", 13, color)), (Star(), VStack(4, Paragraph(signal.Text("signal"), 13, Txt), signal.Text("evidence").Length > 0 ? Paragraph(signal.Text("evidence"), 11.5) : null)), (Auto, Sans(verdict == "hit" ? "命中" : verdict == "partial" ? "部分" : "未命中", 10.5, color))));
        }
        if (evaluation is null) right.Children.Add(Sans("这一题没有评估结果", 12.5, Fnt)); right.Children.Add(Divider());
        if (evaluation.Items("highlights").Count > 0 || evaluation.Items("weaknesses").Count > 0) right.Children.Add(Columns(20, (Star(), Pair("亮点", evaluation.Items("highlights"))), (Star(), Pair("待改进", evaluation.Items("weaknesses")))));
        if (evaluation.Text("reference_answer").Length > 0) right.Children.Add(Card(VStack(10, Sans("参考思路", 12.5, Txt, Medium), Paragraph(evaluation.Text("reference_answer"), 12)), 10, new Thickness(20, 16, 20, 16), Field, Clear));
        if (!_editing)
        {
            right.Children.Add(new V3Button(_busy == "evaluate" ? "正在评估…" : $"重新评估这一题 · 还剩 {Remaining} 次", () => _ = Evaluate()) { Enabled = Remaining > 0 && _busy is null });
            if (index >= 0 && index < rows.Count - 1) right.Children.Add(LinkButton($"下一题 · Q{rows[index + 1].No} {rows[index + 1].Topic} ›", () => Navigate(rows[index + 1].Id)));
        }
        _body.Children.Add(Columns(60, (Star(484), left), (Star(496), right)).Top(28));
    }
    void Navigate(string? id) => Leave(() => _open(id));
    void NavigateHome() => Leave(_home);
    void Leave(Action action)
    {
        if (_busy is not null) return;
        if (_editing && _drafts.Any(p => _row.Turns.FirstOrDefault(t => t.Display("id") == p.Key).Text("answer_text") != p.Value) && XamlRoot is not null)
        {
            _leaveDialog = V3Overlay.Show(XamlRoot, close => V3Dialog.Make(VStack(12, V3DialogHead.Make("放弃未保存的识别稿？"), Paragraph("离开后，这次尚未保存的修改会丢失。")), [new V3Button("继续修改", close), new V3Button("放弃修改", () => { close(); action(); })], close)); return;
        }
        action();
    }
    UIElement Turn(JsonNode turn, int position)
    {
        var id = turn.Display("id"); var depth = Math.Max(1, turn.Number("depth_level") ?? 1); var changes = turn.Text("transcript_state") == "corrected" ? turn.Get("correction").Items("changes").Select(c => c.Text("corrected")).Where(c => c.Length > 0).ToList() : [];
        var text = _raw && turn.Text("raw_transcript").Length > 0 ? turn.Text("raw_transcript") : turn.Text("answer_text");
        var block = VStack(12, V3Chip.Make($"{(position == 0 ? "主问题" : "追问")} · 第 {(int)depth} 层 · {Level(depth)}", size: 10.5), Line("面试官", turn.Text("content"), true));
        if (turn.Bool("has_recording") && !_detail.Bool("recordings_deleted")) block.Children.Add(AudioBar(turn).Pad(52, 0, 0, 0));
        if (turn.Text("answer_status") == "skipped") block.Children.Add(Line("你", "跳过了这道题", grey: true));
        else if (_editing && Editable.Any(t => t.Display("id") == id))
        {
            var draft = _drafts.GetValueOrDefault(id, turn.Text("answer_text"));
            var editor = new TextBox { Text = draft, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 88, MaxLength = 8000, FontSize = 13, FontFamily = SansFamily, IsEnabled = _busy is null, PlaceholderText = "修改识别稿" };
            var hint = Sans("直接改识别错的地方", 10.5, Fnt).Wrap();
            void Hint()
            {
                var original = turn.Text("raw_transcript").NonEmpty() ?? turn.Text("answer_text");
                hint.Text = editor.Text == turn.Text("answer_text") ? "直接改识别错的地方" : "已改 · 原识别「" + (original.Length > 18 ? original[..18] + "…" : original) + "」";
                if (ChangeRatio(original, editor.Text) > .5) hint.Text += " · 改动较大，评估仍以修改后的文字为准";
            }
            editor.TextChanged += (_, _) => { _drafts[id] = editor.Text; Hint(); }; Hint();
            block.Children.Add(Card(VStack(10, editor, hint), 8, new Thickness(12, 10, 12, 10), White, Hex(0xC9D6F3)).Pad(52, 0, 0, 0));
        }
        else block.Children.Add(Line("你", text.Length == 0 ? "这道题没有作答" : text, marks: _raw ? [] : changes));
        block.Children.Add(Divider()); return block;
    }
    static FrameworkElement Pair(string title, List<JsonNode> values) => VStack(6, Sans(title, 12, Txt, Medium), Paragraph(values.FirstOrDefault()?.String() ?? "—", 12));
    static FrameworkElement Line(string who, string text, bool blue = false, bool grey = false, List<string>? marks = null)
    {
        var copy = Paragraph(text, 13, grey ? Fnt : Txt);
        if (marks is { Count: > 0 })
        {
            copy.Inlines.Clear(); var offset = 0;
            while (offset < text.Length)
            {
                var first = marks.Select(mark => (Mark: mark, Index: text.IndexOf(mark, offset, StringComparison.Ordinal))).Where(m => m.Index >= offset && m.Mark.Length > 0).OrderBy(m => m.Index).FirstOrDefault();
                if (first.Mark is null) { copy.Inlines.Add(new Run { Text = text[offset..] }); break; }
                copy.Inlines.Add(new Run { Text = text[offset..first.Index] }); var underline = new Underline(); underline.Inlines.Add(new Run { Text = first.Mark, Foreground = Brush(Blue) }); copy.Inlines.Add(underline); offset = first.Index + first.Mark.Length;
            }
        }
        return Columns(0, (Px(52), Sans(who, 10.5, blue ? Blue : Fnt)), (Star(), copy));
    }
    FrameworkElement AudioBar(JsonNode turn)
    {
        var id = turn.Display("id"); var active = _playing == id && _player?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
        var button = new V3Button(active ? "暂停" : "播放", () => _ = Play(turn), V3Button.Kind.Dark, height: 28).Tip(active ? "暂停录音" : "播放录音");
        var progress = new Slider { Minimum = 0, Maximum = Math.Max(1, (turn.Number("audio_duration_ms") ?? 0) / 1000), Width = 170, IsEnabled = _playing == id && _player is not null };
        _audioSliders[id] = progress;
        if (_playing == id && _player is not null) progress.Value = Math.Min(progress.Maximum, _player.PlaybackSession.Position.TotalSeconds);
        progress.ValueChanged += (_, e) => { if (_playing == id && _player is not null && Math.Abs(_player.PlaybackSession.Position.TotalSeconds - e.NewValue) > 1) _player.PlaybackSession.Position = TimeSpan.FromSeconds(e.NewValue); };
        var seconds = (int)Math.Round((turn.Number("audio_duration_ms") ?? 0) / 1000); return HStack(10, button, progress, Sans($"{seconds / 60:00}:{seconds % 60:00}", 11, Fnt));
    }
    async Task Play(JsonNode turn)
    {
        if (_life is null || !_life.Alive) return; var id = turn.Display("id");
        if (_playing == id && _player is not null) { if (_player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing) _player.Pause(); else _player.Play(); Render(); return; }
        StopAudio(); var generation = ++_playGeneration;
        try
        {
            if (App.Session.Api is not HttpApiClient client) throw new InvalidOperationException("音频传输不可用");
            var bytes = await client.Coordinator.MockAudioAsync(Base + $"/questions/{id}/recording", "GET", null, _life.Token);
            if (!_life.Alive || generation != _playGeneration) return;
            var stream = new InMemoryRandomAccessStream();
            try { using var writer = new DataWriter(stream.GetOutputStreamAt(0)); writer.WriteBytes(bytes); await writer.StoreAsync(); await writer.FlushAsync(); }
            catch { stream.Dispose(); throw; }
            if (!_life.Alive || generation != _playGeneration) { stream.Dispose(); return; }
            _audio = stream; _audio.Seek(0); _player = new MediaPlayer { Source = MediaSource.CreateFromStream(_audio, "audio/wav") }; _playing = id;
            _player.MediaEnded += (_, _) => DispatcherQueue.TryEnqueue(() => { if (generation != _playGeneration) return; StopAudio(); if (_life.Alive) Render(); });
            _player.MediaFailed += (_, _) => DispatcherQueue.TryEnqueue(() => { if (generation != _playGeneration) return; StopAudio(); if (_life.Alive) { _notice = "录音播放失败"; Render(); } });
            _audioTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
            _audioTimer.Tick += (_, _) =>
            {
                if (_player is null || _playing is null || !_audioSliders.TryGetValue(_playing, out var slider)) return;
                var duration = _player.PlaybackSession.NaturalDuration.TotalSeconds;
                if (duration > 0) slider.Maximum = duration;
                slider.Value = Math.Clamp(_player.PlaybackSession.Position.TotalSeconds, 0, slider.Maximum);
            };
            _audioTimer.Start(); _player.Play(); Render();
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (_life.Alive && generation == _playGeneration) { StopAudio(); _notice = "录音读取失败 · " + Error(e); Render(); } }
    }
    void StopAudio() { _audioTimer?.Stop(); _audioTimer = null; _playGeneration++; _player?.Pause(); _player?.Dispose(); _player = null; _audio?.Dispose(); _audio = null; _playing = null; }
    void Update(JsonNode result)
    {
        if (result.Get("mock_interview") is not {} next) return; _detail = next; _row = Rows(next).FirstOrDefault(r => r.Id == _row.Id) ?? _row; _updated(next);
    }
    async Task Work(string kind, Func<Task> action)
    {
        if (_busy is not null || _life is null || !_life.Alive) return; _busy = kind; _notice = null; Render();
        try { await action(); } catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) _notice = Error(e); }
        finally { _busy = null; if (_life.Alive) Render(); }
    }
    Task Correct() => Work("correct", async () => { var result = await _life!.Request(Base + "/transcripts:correct", "POST"); Update(result); var count = result.Items("items").Sum(i => i.Items("changes").Count); _notice = count > 0 ? $"已修正 {count} 处识别错误" : "识别稿没有需要修正的地方"; });
    Task Evaluate() => Work("evaluate", async () =>
    {
        if (Remaining <= 0) return; var result = await _life!.Request(Base + $"/questions/{_row.Id}/re-evaluate", "POST"); Update(result);
        _notice = $"这一题重新评估了：{result.Number("previous_total_score"):F0} → {result.Number("total_score"):F0} · 还剩 {result.Integer("remaining")} 次";
    });
    Task Save() => Work("save", async () =>
    {
        var changed = Editable.Where(t => _drafts.TryGetValue(t.Display("id"), out var text) && text != t.Text("answer_text")).Select(t => (Id: t.Display("id"), Text: _drafts[t.Display("id")])).ToList();
        // Apply each authoritative response immediately, so partial saves remain visible and retryable.
        foreach (var (id, text) in changed) { var result = await _life!.Request(Base + $"/questions/{id}/transcript", "PUT", new JsonObject { ["text"] = text }); Update(result); _drafts.Remove(id); }
        _editing = false; _drafts.Clear(); _notice = "识别稿已保存。";
        if (Remaining > 0)
        {
            try { var result = await _life!.Request(Base + $"/questions/{_row.Id}/re-evaluate", "POST"); Update(result); _notice = $"已保存并重新评估这一题 · 还剩 {result.Integer("remaining")} 次 · 不另扣积分"; }
            catch (OperationCanceledException) { throw; }
            catch (Exception e) { _notice = "识别稿已保存，但没有重新评估 · " + Error(e); }
        }
    });
    static double ChangeRatio(string original, string next) => MockReview.ChangeRatio(original, next);
}
