using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerStageDetailView
{
    // MARK: Side

    UIElement ReportCard()
    {
        var card = new StackPanel { Spacing = 12 };
        var head = Spread(Sans("AI 分析报告", 13, CareerPalette.Text, Medium),
            Report is { } generated ? Mono(CareerFormat.MonthDay(generated.Text("generated_at")) + " " + CareerFormat.Clock(generated.Text("generated_at")), 11, CareerPalette.Faint, Medium) : new Border(), 8);
        card.Children.Add(head);
        if (Report is { } report && CareerReview.IsV2(report))
        {
            var score = HStack(2, Serif(CareerReview.Score100(report)?.ToString() ?? "—", 22), Sans(" / 100", 11, CareerPalette.Hint));
            score.Children[1].SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Bottom);
            ((FrameworkElement)score.Children[1]).Margin = new Thickness(0, 0, 0, 4);
            card.Children.Add(Spread(CareerChipView.Make(CareerReview.Verdict(report.Get("verdict").Text("level"))), score, 8));
            card.Children.Add(Sans(report.Text("headline"), 13, CareerPalette.Text, Medium).Wrap());
            card.Children.Add(Bars(report.Items("dimensions").Select(item =>
            {
                var assessed = item.Bool("assessed");
                return (CareerReview.DimensionLabel(item.Text("key")), assessed ? (int?)item.Integer("score") : null, assessed ? $"{item.Integer("score")} / 5" : "未评估");
            }).ToList()));
            foreach (var child in ReportFooter()) card.Children.Add(child);
        }
        else if (Report is { } legacy)
        {
            card.Children.Add(Sans(legacy.Text("summary"), 13, CareerPalette.Text, Medium).Wrap());
            card.Children.Add(Bars(new[] { ("项目表达", "project_expression"), ("系统设计", "system_design"), ("沟通表达", "communication") }.Select(entry =>
            {
                int? score = legacy.Get(entry.Item2).Number("score") is { } value ? (int)Round(value / 2) : null;
                return (entry.Item1, score, score is { } s ? $"{s} / 5" : "—");
            }).ToList()));
            foreach (var child in ReportFooter()) card.Children.Add(child);
        }
        else
        {
            var failed = Session.Text("review_status") == "failed";
            card.Children.Add(CareerChipView.Make(Generating ? "正在生成" : failed ? "生成失败" : "待生成", failed ? CareerTone.Red : CareerTone.Gray));
            card.Children.Add(Sans(RecordText.Length == 0 ? "添加文字稿后，AI 会按问题拆分回答并给出改进建议" : "结合文字稿、投递简历、岗位要求和资料库内容，逐题打分并给出改进建议", 12, CareerPalette.Hint).Wrap());
            card.Children.Add(new CareerAction(Generating ? "正在生成…" : "AI 复盘", () => Open(Sheet.Analysis), CareerAction.Kind.Primary) { Enabled = !(RecordText.Length == 0 || Generating || Archived) });
        }
        return card.CareerCard();
    }

    IEnumerable<UIElement> ReportFooter()
    {
        if (Session.Bool("review_stale")) yield return Sans("文字记录已修改，可以重新生成报告", 12, CareerPalette.Hint).Wrap();
        if (Generating) yield return Sans("正在后台重新生成…", 12, CareerPalette.Hint).Wrap();
        yield return new CareerAction("查看完整报告 →", _openReport);
    }

    static UIElement Bars(List<(string Label, int? Score, string Text)> rows)
    {
        CareerTone[] tones = [CareerTone.Green, CareerTone.Blue, CareerTone.Orange, CareerTone.Green, CareerTone.Blue];
        var stack = new StackPanel { Spacing = 8 };
        for (var index = 0; index < rows.Count; index++)
        {
            var row = rows[index];
            var dots = HStack(3);
            for (var dot = 0; dot < 5; dot++)
                dots.Children.Add(new Border { Width = 16, Height = 4, CornerRadius = new CornerRadius(2), Background = Brush((row.Score ?? 0) > dot ? CareerPalette.Solid(tones[index % tones.Length]) : CareerPalette.Border) });
            var value = Mono(row.Text, 11, CareerPalette.Sub, Medium);
            value.MinWidth = 38;
            value.TextAlignment = TextAlignment.Right;
            stack.Children.Add(Columns(10, (Star(), Sans(row.Label, 12, CareerPalette.Sub)), (Auto, dots), (Auto, value)));
        }
        return stack;
    }

    UIElement NotesCard()
    {
        var summary = Session.Text("review_summary").Trim();
        var improvement = Session.Text("improvement_markdown").Trim();
        var noteCount = Session.Items("review_question_notes").Count;
        var card = new StackPanel { Spacing = 12 };
        card.Children.Add(Sans("复盘笔记", 13, CareerPalette.Text, Medium));
        if (noteCount > 0) card.Children.Add(Sans($"逐题笔记 {noteCount} 条，在完整报告的题目里查看", 12, CareerPalette.Hint).Wrap());
        if (summary.Length == 0 && improvement.Length == 0) card.Children.Add(Sans("按题记下回答与改进点，下一轮前回看", 12, CareerPalette.Hint).Wrap());
        else card.Children.Add(NoteBlock(summary.Length == 0 ? improvement : summary, clamped: true));
        if (!Archived) card.Children.Add(new CareerAction(summary.Length == 0 && improvement.Length == 0 ? "写复盘" : "继续写复盘 →", () => Open(Sheet.Notes)));
        return card.CareerCard();
    }

    UIElement InfoCard()
    {
        var status = CareerTranscript.Status(Session, Application, _now);
        var rows = new List<CareerInfoRow>
        {
            new("时间", CareerFormat.Range(Session.Text("start_at"), Session.Text("end_at"))),
            new("方式", CareerSessions.ModeText(Session)),
        };
        if (!IsWritten) rows.Add(new("面试官", string.Join(" · ", new[] { Session.Text("interviewer_name"), Session.Text("interviewer_title") }.Where(x => x.Length > 0)).Or("—")));
        var count = CareerTranscript.Questions(RecordText).Count;
        if (IsWritten && count > 0) rows.Add(new("题量", $"{count} 题"));
        rows.Add(new("结果", status.Label, status.Tone == CareerTone.Gray ? null : status.Tone));
        return VStack(12, Sans(IsWritten ? "本场信息" : "本轮信息", 13, CareerPalette.Text, Medium), CareerInfoRows.Make(rows)).CareerCard();
    }

    // MARK: Sheets

    void Open(Sheet kind)
    {
        if (XamlRoot is null || _sheet?.IsOpen == true) return;
        void Done() { _sheet?.Close(); Refresh(); }
        _sheet = V3Overlay.Show(XamlRoot, close => kind switch
        {
            Sheet.Upload or Sheet.Library or Sheet.Text => new CareerAddContentSheet(Session, Kind,
                kind == Sheet.Upload ? CareerAddContentSheet.Mode.Upload : kind == Sheet.Library ? CareerAddContentSheet.Mode.Library : CareerAddContentSheet.Mode.Text, close, Done),
            Sheet.Edit => new CareerTextSheet($"编辑{Kind}文字记录", $"修改已保存的{Kind}文字记录。", RecordText, Session, close, Done),
            Sheet.Notes => new CareerNotesSheet(Session, close, Done),
            Sheet.Analysis => new CareerAnalysisSheet(_detail, Audio?.Text("original_file_name"), close, () => { _sheet?.Close(); Refresh(); _openReport(); }),
            Sheet.ImportQuestions => new CareerWrittenImportSheet(_detail, close, count => { _sheet?.Close(); _notice = $"已导入 {count} 道题。"; Refresh(); }),
            Sheet.Reschedule => new CareerRescheduleSheet(Session, close, Done),
            _ => new CareerPlanSheet(Session, close, Done),
        }, dismissible: false);
    }

    // MARK: Requests

    async Task LoadAsync(bool quiet = false)
    {
        var request = ++_request;
        if (!quiet) { _loading = true; _error = null; Render(); }
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}");
            if (request != _request || !_alive) return;
            if (result.Get("session").Text("id").Length == 0) throw new InvalidDataException();
            _detail = result; _now = Beijing.Now;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error)
        {
            Fail(error);
            if (request != _request || !_alive) return;
            if (!quiet) _error = "暂时无法读取这条记录。";
        }
        if (!quiet) _loading = false;
        Render();
    }

    /// <summary>转写与复盘生成在后台完成：进行中每 10 秒静默刷新一次。</summary>
    void UpdatePolling()
    {
        var active = _alive && (Transcribing || Generating);
        if (!active) { StopPolling(); return; }
        if (_poll is not null) return;
        _poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        _poll.Tick += (_, _) => _ = LoadAsync(quiet: true);
        _poll.Start();
    }

    void StopPolling() { _poll?.Stop(); _poll = null; }

    async Task UpdateAsync(JsonObject fields)
    {
        _busy = true; Render();
        fields["base_lock_version"] = Lock(Session);
        try { await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}", "PUT", body: fields); _busy = false; Refresh(); }
        catch (Exception error) { Fail(error); _notice = CareerErrors.Message(error); _busy = false; Render(); }
    }

    async Task ClearPlanAsync()
    {
        _busy = true; Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}/answer-plan", "PUT",
                body: new JsonObject { ["base_lock_version"] = Lock(Session), ["answer_plan_start_at"] = null, ["answer_plan_end_at"] = null });
            _busy = false; Refresh();
        }
        catch (Exception error) { Fail(error); _notice = CareerErrors.Message(error); _busy = false; Render(); }
    }

    async Task TranscriptionCommandAsync(string command)
    {
        if (Audio is not { } audio) return;
        _busy = true; Render();
        JsonNode? body = command == "apply" ? new JsonObject { ["base_lock_version"] = Lock(Session) } : null;
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}/transcriptions/{audio.Text("id")}:{command}", "POST", body: body);
            if (command == "apply") _notice = "已用转写结果替换文字稿。";
            _busy = false; Refresh();
        }
        catch (Exception error) { Fail(error); _notice = CareerErrors.Message(error); _busy = false; Render(); }
    }
}

/// <summary>
/// 录音播放器（Mac `CareerAudioBar`）：录音经本人资料源下载到私有临时目录，本地播放；离开页面时停止并删除临时文件。
/// 28 圆形播放钮、11px 等宽时间、48 根装饰波形（2.5 宽、高 6 + (i×7) mod 13），左右 14、上下 10，圆角 12。
/// </summary>
public sealed class CareerAudioBar : UserControl
{
    readonly JsonNode _asset;
    readonly Action<string> _notice;
    Windows.Media.Playback.MediaPlayer? _player;
    DatasetFile? _file;
    bool _playing, _loading;
    double _playhead;
    readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromSeconds(0.5) };
    readonly Border _toggle = new() { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = Brush(CareerPalette.Text) };
    readonly TextBlock _clock = Mono("00:00", 11, CareerPalette.Sub, Medium);
    readonly List<Border> _bars = [];

    public string AssetId => _asset.Text("id");
    double Total => (_asset.Number("duration_ms") ?? 0) / 1000;

    public CareerAudioBar(JsonNode asset, Action<string> notice)
    {
        _asset = asset;
        _notice = notice;
        _toggle.OnTap(() => _ = ToggleAsync(), "播放录音", () => !_loading);
        var wave = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, Height = 22, VerticalAlignment = VerticalAlignment.Center };
        for (var index = 0; index < 48; index++)
        {
            var bar = new Border { Width = 2.5, Height = 6 + (index * 7) % 13, CornerRadius = new CornerRadius(1), VerticalAlignment = VerticalAlignment.Center };
            _bars.Add(bar);
            wave.Children.Add(bar);
        }
        var clip = new Border { Child = wave, Height = 22, HorizontalAlignment = HorizontalAlignment.Stretch };
        clip.SizeChanged += (_, e) => clip.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        Hidden(clip);
        var row = Columns(10, (Auto, _toggle), (Auto, _clock), (Star(), clip), (Auto, Mono(Total > 0 ? Stamp(Total) : "—", 11, CareerPalette.Sub, Medium)));
        Content = new Border
        {
            Child = row, Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(12), Background = Brush(CareerPalette.Soft),
            BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
        }.Named("面试录音播放器");
        _ticker.Tick += (_, _) => Tick();
        Unloaded += (_, _) => { if (Parent is null) Stop(); };
        Paint();
    }

    void Tick()
    {
        if (_player is null) return;
        var position = _player.PlaybackSession.Position.TotalSeconds;
        _playhead = double.IsFinite(position) ? position : 0;
        _playing = _player.PlaybackSession.PlaybackState == Windows.Media.Playback.MediaPlaybackState.Playing;
        Paint();
    }

    void Paint()
    {
        _toggle.Child = Icon(_playing ? "pause.fill" : "play.fill", 11, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        _toggle.Named(_playing ? "暂停录音" : "播放录音");
        _toggle.Opacity = _loading ? 0.6 : 1;
        _clock.Text = Stamp(_playhead);
        for (var index = 0; index < _bars.Count; index++)
            _bars[index].Background = Brush(Total > 0 && (double)index / 48 < _playhead / Total ? CareerPalette.Text : Hex(0xC9C9C3));
    }

    async Task ToggleAsync()
    {
        if (_player is { } player)
        {
            if (player.PlaybackSession.PlaybackState == Windows.Media.Playback.MediaPlaybackState.Playing) player.Pause(); else player.Play();
            return;
        }
        _loading = true; Paint();
        try
        {
            var downloaded = await App.Session.Api.DownloadDatasetAsync(_asset.Text("id"), 512L * 1024 * 1024);
            var ext = System.IO.Path.GetExtension(_asset.Text("original_file_name")).TrimStart('.').ToLowerInvariant();
            var playable = System.IO.Path.Combine(downloaded.Directory, "recording." + (ext.Length == 0 ? "m4a" : ext));
            File.Move(downloaded.File, playable);
            _file = downloaded;
            var source = await Windows.Storage.StorageFile.GetFileFromPathAsync(playable);
            _player = new Windows.Media.Playback.MediaPlayer { Source = Windows.Media.Core.MediaSource.CreateFromStorageFile(source) };
            _player.Play();
            _ticker.Start();
        }
        catch (Exception error) { Fail(error); _notice("录音加载失败，请稍后重试。"); }
        finally { _loading = false; Paint(); }
    }

    public void Stop()
    {
        _ticker.Stop();
        _player?.Pause();
        _player?.Dispose();
        _player = null;
        _file?.Discard();
        _file = null;
        _playing = false;
    }
}
