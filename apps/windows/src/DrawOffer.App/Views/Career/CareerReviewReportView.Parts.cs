using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerReviewReportView
{
    // MARK: Requests

    async Task LoadAsync(bool quiet = false)
    {
        var request = ++_request;
        if (!quiet) { _loading = true; _error = null; Render(); }
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}");
            if (request != _request || !_alive) return;
            if (result.Get("session") is not { } loaded || loaded.Text("id").Length == 0) throw new InvalidDataException();
            var wasGenerating = Generating;
            _detail = result; _now = DateTimeOffset.Now;
            if (loaded.Text("review_status") != "generating" && _attempt?.Id == loaded.Text("review_request_id")) _attempt = null;
            if (quiet && wasGenerating && loaded.Text("review_status") == "failed") _notice = "复盘生成失败，原记录和已有报告已保留。";
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error)
        {
            Fail(error);
            if (request != _request || !_alive) return;
            if (!quiet) _error = "暂时无法读取这份报告。";
        }
        if (!quiet) _loading = false;
        Render();
    }

    /// <summary>生成中每 3 秒刷新一次，同时更新「已中断」判断用的当前时间。</summary>
    void UpdatePolling()
    {
        if (!(_alive && Generating)) { StopPolling(); return; }
        if (_poll is not null) return;
        _poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _poll.Tick += (_, _) => { _now = DateTimeOffset.Now; _ = LoadAsync(quiet: true); };
        _poll.Start();
    }

    void StopPolling() { _poll?.Stop(); _poll = null; }

    async Task GenerateAsync()
    {
        if (_busy || !CanGenerate || (Generating && !Interrupted)) return;
        // 传输结果未知时保留原请求，重试不会开始第二次生成
        var request = _attempt ?? (Guid.NewGuid().ToString("D"), Session.Number("lock_version") is { } version ? (int)version : 1);
        _attempt = request;
        _busy = true; Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}/review:generate", "POST",
                body: new JsonObject { ["request_id"] = request.Id, ["base_lock_version"] = request.Version });
            if (result.Get("session") is { } updated && _detail is JsonObject fields) fields["session"] = updated.DeepClone();
            if (Session.Text("review_status") != "generating") _attempt = null;
            _busy = false; Render();
        }
        catch (Exception error)
        {
            Fail(error);
            var server = Server(error, out var status, out var code);
            if (server && status is 400 or 404 or 409) _attempt = null;
            if (Unauthorized(error)) _attempt = null;
            _notice = server && code == "LLM_MODEL_NOT_CONFIGURED" ? CareerErrors.Message(error) : "复盘生成失败，原记录和已有报告已保留。";
            _busy = false;
            await LoadAsync(quiet: true);
        }
    }

    void ReplaceNote(JsonNode? note, string key)
    {
        if (_detail is not JsonObject detail || Session is not JsonObject session) return;
        var notes = session.Items("review_question_notes").Where(x => x.Text("question_key") != key).Select(x => x.DeepClone()).ToList();
        if (note is not null) notes.Add(note.DeepClone());
        session["review_question_notes"] = new JsonArray(notes.ToArray());
        detail["session"] = session.DeepClone();
        Render();
    }

    async Task DeleteNoteAsync(JsonNode note)
    {
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_sessionId}/review-notes/{note.Text("id")}", "DELETE");
            ReplaceNote(null, note.Text("question_key"));
        }
        catch (Exception error) { Fail(error); _notice = CareerErrors.Message(error); Render(); }
    }

    async Task LoadTargetsAsync()
    {
        _busy = true; Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/interview-sessions", "GET", new Dictionary<string, string> { ["application_id"] = Application.Text("id"), ["status"] = "scheduled" });
            _targets = result.Items("items").Where(x => x.Text("id") != _sessionId).ToList();
            if (_targets.Count == 0) _notice = "请先为这个岗位安排下一轮面试。";
        }
        catch (Exception error) { Fail(error); _notice = "准备清单加载失败，请稍后重试。"; }
        _busy = false; Render();
    }

    async Task AddToPrepAsync(JsonNode question, string targetId)
    {
        _busy = true; Render();
        try
        {
            var target = (await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{targetId}")).Get("session") ?? new JsonObject();
            if (target.Text("status") != "scheduled") throw new InvalidDataException();
            var title = Prefix(question.Text("question"), 80);
            var items = target.Items("prep_items").Select(x => x.DeepClone()).ToList();
            if (items.Any(x => x.Text("title") == title)) { _notice = "这个问题已在准备清单中。"; _busy = false; Render(); return; }
            if (items.Count >= 12) { _notice = "准备清单已满，请先整理已有事项。"; _busy = false; Render(); return; }
            var advice = question.Text("suggested_answer").Or(question.Text("improvement"));
            var section = $"## {Session.Text("stage_label")} · Q{_selected + 1}\n{question.Text("question")}\n\n{advice}";
            var note = string.Join("\n\n", new[] { target.Text("preparation_note"), section }.Where(x => x.Length > 0));
            if (Count(note) > 100_000) throw new InvalidDataException();
            var reason = question.Text("improvement").Or(question.Text("suggested_answer")).Or(question.Text("evidence")).Or(question.Text("question"));
            items.Add(new JsonObject { ["id"] = Guid.NewGuid().ToString("D"), ["title"] = title, ["category"] = "technical", ["reason"] = Prefix(reason, 200), ["done"] = false });
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{targetId}", "PUT",
                body: new JsonObject { ["preparation_note"] = note, ["prep_items"] = new JsonArray(items.ToArray()), ["base_lock_version"] = Lock(target) });
            _notice = "已保存到下一轮准备清单。"; _targets = [];
        }
        catch (Exception error) { Fail(error); _notice = "准备清单保存失败，请刷新后重试。"; }
        _busy = false; Render();
    }
}

/// <summary>五维雷达（Mac `CareerRadar`）：每轴 1–5，未评估的轴画在中心。画布 220、半径 78，标签离轴端横向 20、纵向 14。</summary>
public static class CareerRadar
{
    public static FrameworkElement Make(IReadOnlyList<JsonNode> dimensions)
    {
        const double size = 220, center = size / 2, radius = 78;
        List<double?> values = dimensions.Select(x => x.Bool("assessed") ? x.Number("score") : null).ToList();
        var draw = new Draw(size, size);
        static Point P((double X, double Y) point) => new(point.X, point.Y);
        for (var level = 1; level <= 5; level++)
            draw.Stroke(Draw.Lines(CareerReview.RadarPoints(values.Select(_ => (double?)level).ToList(), radius, center).Select(P), closed: true), CareerPalette.Border, 1);
        draw.Stroke(Draw.Segments(CareerReview.RadarPoints(values.Select(_ => (double?)5).ToList(), radius, center).Select(point => (new Point(center, center), P(point)))), CareerPalette.Border, 1);
        var shape = Draw.Lines(CareerReview.RadarPoints(values, radius, center).Select(P), closed: true);
        draw.Fill(shape, Draw.A(Hex(0x2B2B27), 0.12));
        draw.Stroke(Draw.Lines(CareerReview.RadarPoints(values, radius, center).Select(P), closed: true), CareerPalette.Text, 1.5);
        for (var index = 0; index < dimensions.Count; index++)
        {
            var item = dimensions[index];
            var angle = -Math.PI / 2 + index * 2 * Math.PI / Math.Max(dimensions.Count, 1);
            double x = center + (radius + 20) * Math.Cos(angle), y = center + (radius + 14) * Math.Sin(angle);
            var assessed = item.Bool("assessed");
            var label = Sans($"{CareerReview.DimensionLabel(item.Text("key"))} {(assessed ? $"{item.Integer("score")}" : "—")}", 10, assessed ? CareerPalette.Sub : CareerPalette.Faint, Medium);
            label.TextTrimming = TextTrimming.None;
            var anchor = Math.Abs(x - center) < 4 ? 0.5 : x > center ? 0 : 1;
            draw.Text(label, new Point(x, y), anchor, 0.5);
        }
        draw.Surface.IsHitTestVisible = false;
        return new Viewbox { Child = draw.Surface, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform }.Named("能力雷达");
    }
}

/// <summary>报告每道题下的「我的复盘笔记」（Mac `CareerQuestionNote`）：答得好 / 待改进切换加自由文字，按题保存。</summary>
public sealed class CareerQuestionNote : UserControl
{
    readonly JsonNode _session;
    readonly string _questionText;
    readonly JsonNode? _note;
    readonly bool _disabled;
    readonly Action<JsonNode?> _saved;
    string? _verdict;
    string _state = "";
    readonly CareerTextArea _draft;

    public CareerQuestionNote(JsonNode session, string questionText, JsonNode? note, bool disabled, Action<JsonNode?> saved)
    {
        (_session, _questionText, _note, _disabled, _saved) = (session, questionText, note, disabled, saved);
        _draft = new CareerTextArea("", note.Text("note"), "记下这道题哪里卡住了、下次怎么答", 84);
        _draft.Box.IsEnabled = !disabled;
        _verdict = note.Text("verdict").NonEmpty();
        _draft.Box.TextChanged += (_, _) => { if (_state != "saving") _state = ""; Render(); };
        Render();
    }

    bool Dirty => _draft.Text.Trim() != (_note.Text("note")) || _verdict != _note.Text("verdict").NonEmpty();

    void Render() => KeepFocus(XamlRoot, Rebuild);

    void Rebuild()
    {
        var toggles = HStack(6).Named("这道题答得怎么样");
        foreach (var value in new[] { "good", "improve" })
        {
            var on = _verdict == value;
            var title = value == "good" ? "答得好" : "待改进";
            var pill = new Border
            {
                Child = Sans(title, 11.5, on ? V3.White : CareerPalette.Sub), Padding = new Thickness(10, 3, 10, 3), CornerRadius = new CornerRadius(12),
                Background = Brush(on ? CareerPalette.Text : V3.White), BorderBrush = Brush(on ? CareerPalette.Text : CareerPalette.Border), BorderThickness = new Thickness(1),
                Opacity = _disabled || _state == "saving" ? 0.6 : 1,
            };
            toggles.Children.Add(pill.OnTap(() => { var next = _verdict == value ? null : value; _verdict = next; _ = SaveAsync(next); }, title, () => !(_disabled || _state == "saving")));
        }
        var status = new Dictionary<string, string> { ["saving"] = "正在保存…", ["saved"] = "已保存", ["conflict"] = "笔记已在其他页面更新，请刷新后再试。", ["error"] = "保存失败，请稍后重试。" }.GetValueOrDefault(_state, "");
        var stack = VStack(8,
            Spread(Sans("我的复盘笔记", 12.5, CareerPalette.Text, Medium), toggles, 8),
            Detach(_draft),
            Spread(Sans(status, 11.5, CareerPalette.Faint).Wrap(), new CareerAction("保存笔记", () => _ = SaveAsync(_verdict)) { Enabled = !(_disabled || !Dirty || _state == "saving") }, 8));
        Content = new Border { Child = stack, Padding = new Thickness(14), CornerRadius = new CornerRadius(12), Background = Brush(CareerPalette.Soft) };
    }

    async Task SaveAsync(string? nextVerdict)
    {
        _state = "saving"; Render();
        var text = _draft.Text.Trim();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}/review-notes", "PUT", body: new JsonObject
            {
                ["question_text"] = _questionText, ["verdict"] = nextVerdict, ["note"] = text.Length == 0 ? null : text, ["lock_version"] = _note.Get("lock_version")?.DeepClone(),
            });
            _state = "saved";
            var saved = result.Get("note") is JsonNode value && value.GetValueKind() != System.Text.Json.JsonValueKind.Null ? value : null;
            Render();
            _saved(saved);
        }
        catch (Exception error)
        {
            Fail(error);
            _state = Server(error, out var status, out _) && status == 409 ? "conflict" : "error";
            Render();
        }
    }
}
