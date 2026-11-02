using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using Shapes = Microsoft.UI.Xaml.Shapes;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerApplicationDetailView
{
    // MARK: History and side cards

    UIElement History(CareerDetailModel model)
    {
        var visible = _showAllHistory || model.History.Count <= 5 ? model.History : model.History.Take(4).ToList();
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(Sans("阶段记录", 15, CareerPalette.Text, Medium).Pad(0, 0, 0, 2));
        if (visible.Count == 0)
        {
            var bars = new StackPanel { Spacing = 8, Margin = new Thickness(0, 0, 0, 8), HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var width in new[] { 120, 96, 72 })
                bars.Children.Add(HStack(8, new Shapes.Ellipse { Width = 8, Height = 8, Stroke = Brush(CareerPalette.Dashed), StrokeThickness = 1.5 },
                    new Border { Width = width, Height = 8, CornerRadius = Capsule(8), Background = Brush(CareerPalette.PipelineLine) }));
            var empty = VStack(6, bars, Sans("还没有阶段记录", 13, CareerPalette.Text, Medium).Align(HorizontalAlignment.Center),
                Sans("记录投递后，筛选、笔试、面试和 Offer 会按时间排在这里", 12, CareerPalette.Faint).Align(HorizontalAlignment.Center));
            var frame = new Shapes.Rectangle { RadiusX = 12, RadiusY = 12, Fill = Brush(CareerPalette.Soft), Stroke = Brush(CareerPalette.Rail), StrokeThickness = 1, StrokeDashArray = [4, 3] };
            stack.Children.Add(Layer(frame, new Border { Child = empty, Padding = new Thickness(24, 28, 24, 28) }));
        }
        for (var index = 0; index < visible.Count; index++)
        {
            var entry = visible[index];
            FrameworkElement dot = entry.Dot is { } tone
                ? new Shapes.Ellipse { Width = 10, Height = 10, Fill = Brush(CareerPalette.Solid(tone)) }
                : new Shapes.Ellipse { Width = 10, Height = 10, Fill = Brush(V3.White), Stroke = Brush(CareerPalette.Faint), StrokeThickness = 1.5 };
            var date = Label(entry.Date, 11, CareerPalette.Faint, Medium).Align(HorizontalAlignment.Center);
            date.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            var axis = new Grid { Width = 52, Padding = new Thickness(0, 16, 0, 0) };
            axis.RowDefinitions.Add(new RowDefinition { Height = Auto });
            axis.RowDefinitions.Add(new RowDefinition { Height = Auto });
            axis.RowDefinitions.Add(new RowDefinition { Height = Star() });
            axis.RowSpacing = 6;
            axis.Children.Add(dot.Align(HorizontalAlignment.Center));
            Grid.SetRow(date, 1); axis.Children.Add(date);
            if (index < visible.Count - 1)
            {
                var line = new Border { Width = 1.5, Background = Brush(CareerPalette.Rail), Margin = new Thickness(0, 0, 0, -14), HorizontalAlignment = HorizontalAlignment.Center };
                Grid.SetRow(line, 2); axis.Children.Add(line);
            }
            var top = Spread(Sans(entry.Title, 14, CareerPalette.Text, Medium), CareerChipView.Make(entry.Chip), 8);
            var link = entry.SessionId is { } id ? new CareerAction("查看详情 →", () => Go(new Route.Stage(id)), CareerAction.Kind.Link) : null;
            UIElement bottom = link is null ? Sans(entry.Detail, 12, CareerPalette.Sub) : Spread(Sans(entry.Detail, 12, CareerPalette.Sub), link, 12);
            var card = new Border
            {
                Child = VStack(4, top, bottom), Padding = new Thickness(16, 12, 16, 12), CornerRadius = new CornerRadius(12), Background = Brush(V3.White),
                BorderBrush = Brush(entry.Highlight is { } highlight ? CareerPalette.Solid(highlight) : CareerPalette.Border), BorderThickness = new Thickness(entry.Highlight is null ? 1 : 1.5),
            };
            stack.Children.Add(Columns(14, (Px(52), axis), (Star(), card)));
        }
        if (visible.Count < model.History.Count)
            stack.Children.Add(new CareerAction($"查看更早 {model.History.Count - visible.Count} 个阶段 ↓", () => { _showAllHistory = true; Render(); }, CareerAction.Kind.Muted) { Margin = new Thickness(66, 0, 0, 0) });
        return stack;
    }

    UIElement Side(CareerDetailModel model)
    {
        var stack = new StackPanel { Spacing = 14 };
        if (model.OfferCard is { } card)
            stack.Children.Add(SideCard(card.Title, card.Action, () => Handle(model.VerbalOffer ? CareerDetailAction.RecordOffer : CareerDetailAction.EditOffer), CareerInfoRows.Make(card.Rows)));
        stack.Children.Add(SideCard("投递信息", model.Pending || !Active ? null : "编辑", ShowJob, CareerInfoRows.Make(model.DeliveryRows)));
        var items = LinkedResources;
        UIElement content;
        if (items.Count == 0) content = Sans("还没有关联简历和资料", 12, CareerPalette.Faint);
        else
        {
            var list = new StackPanel { Spacing = 12 };
            foreach (var resource in items)
            {
                var name = Sans(resource.Name, 12, CareerPalette.Text, Medium);
                name.TextTrimming = TextTrimming.CharacterEllipsis; // truncationMode(.middle) 近似为尾部省略
                list.Children.Add(HStack(10, CareerFileBadge.Make(resource.Name), VStack(0, name, Sans(resource.Meta, 11, CareerPalette.Faint))));
            }
            content = list;
        }
        stack.Children.Add(SideCard("关联资料", "管理", () => WorkspaceShell.Current.Select(WorkspaceSection.Datasets), content));
        return stack;
    }

    List<(string Key, string Name, string Meta)> LinkedResources
    {
        get
        {
            var result = new List<(string, string, string)>();
            if (Raw.Text("resume_id").Length > 0)
            {
                var title = Raw.Text("resume_title_snapshot").NonEmptyOr("投递简历");
                result.Add(("resume", title, "投递简历 · " + CareerFormat.MonthDay(Raw.Text("applied_at").NonEmptyOr(Raw.Text("updated_at")))));
            }
            if (Raw.Text("job_description_id").Length > 0)
                result.Add(("jd", Item.Company + "_岗位JD.md", "岗位要求 · " + CareerFormat.MonthDay(Raw.Text("created_at"))));
            foreach (var asset in _assets)
            {
                var kind = asset.Text("asset_type") switch { "audio" => "面试录音", "video" => "面试视频", _ => "面试材料" };
                result.Add((asset.Text("id"), asset.Text("original_file_name"), kind + " · " + CareerFormat.MonthDay(asset.Text("created_at"))));
            }
            foreach (var material in Raw.Items("offer_materials")) result.Add(("offer-" + material.Text("dataset_id"), material.Text("file_name"), "Offer 材料"));
            return result;
        }
    }

    static UIElement SideCard(string title, string? action, Action onAction, UIElement content)
    {
        UIElement head = action is null
            ? Sans(title, 13, CareerPalette.Text, Medium)
            : Spread(Sans(title, 13, CareerPalette.Text, Medium), new CareerAction(action, onAction, CareerAction.Kind.Link).Also(a => { if (a.Child is StackPanel row) foreach (var t in row.Children.OfType<TextBlock>()) t.FontSize = 11; }));
        return VStack(12, head, content).CareerCard();
    }

    // MARK: Actions

    void Handle(CareerDetailAction action)
    {
        var model = Model;
        switch (action)
        {
            case CareerDetailAction.RecordApplied: _perform("apply", Item); break;
            case CareerDetailAction.Advance: _perform("stage", Item); break;
            case CareerDetailAction.Schedule: _perform("schedule-current", Item); break;
            case CareerDetailAction.RecordReview or CareerDetailAction.AnswerPlan: if (model.CurrentSession?.Text("id") is { } id) Go(new Route.Stage(id)); break;
            case CareerDetailAction.Reschedule: if (model.CurrentSession is { } session) OpenReschedule(session); break;
            case CareerDetailAction.CancelSession: _cancelling = model.CurrentSession; break;
            case CareerDetailAction.RecordOffer or CareerDetailAction.EditOffer: _perform("offer", Item); break;
            case CareerDetailAction.AcceptOffer: _perform("accept", Item); break;
            case CareerDetailAction.DeclineOffer: _perform("decline", Item); break;
            case CareerDetailAction.ViewReview:
                if (model.LatestRecorded?.Text("id") is { } reviewId) Go(new Route.Stage(reviewId));
                else { _notice = "这次求职还没有可查看的复盘记录。"; Render(); }
                break;
        }
    }

    JsonNode LockBody(JsonObject? fields = null)
    {
        var body = fields ?? [];
        body["base_lock_version"] = (double)Raw.Integer("lock_version");
        return body;
    }

    /// <summary>跑一个会改动投递的请求：期间 busy，失败把错误写进 notice。</summary>
    async Task Mutate(Func<Task> run)
    {
        _busy = true; Render();
        try { await run(); }
        catch (Exception error) { Unauthorized(error); _notice = CareerErrors.Message(error); }
        finally { _busy = false; Render(); }
    }

    Task ToggleFavorite() => Mutate(async () =>
    {
        var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{_application.Id}", "PUT", [], LockBody(new JsonObject { ["is_favorite"] = !Raw.Bool("is_favorite") }));
        if (result.Get("application") is { } updated) _current = updated.DeepClone();
    });

    Task Update(JsonObject fields) => Mutate(async () =>
    {
        var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{_application.Id}", "PUT", [], LockBody(fields));
        if (result.Get("application") is { } updated) _current = updated.DeepClone();
    });

    Task Reopen() => Mutate(async () =>
    {
        await App.Session.Api.CareerRequestAsync($"/api/job-applications/{_application.Id}/reopen", "POST", [], LockBody());
        _generation++; _shown = null;
    });

    Task Terminate(string reason) => Mutate(async () =>
    {
        await App.Session.Api.CareerRequestAsync($"/api/job-applications/{_application.Id}/terminate", "POST", [],
            LockBody(new JsonObject { ["client_request_id"] = Guid.NewGuid().ToString().ToLowerInvariant(), ["reason"] = reason }));
        _generation++; _shown = null;
    });

    async Task GeneratePrep(JsonNode session)
    {
        _prepBusy = session.Text("id"); Render(); RefreshPrep();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{session.Text("id")}/prep-items:generate", "POST", [], null);
            _generation++; _shown = null;
        }
        catch (Exception error) { Unauthorized(error); _notice = CareerErrors.Message(error); }
        finally { _prepBusy = null; Render(); RefreshPrep(); }
    }

    async Task Cancel(JsonNode session)
    {
        _cancelling = null;
        await Mutate(async () =>
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{session.Text("id")}/cancel", "POST", [], new JsonObject { ["base_lock_version"] = session.Get("lock_version")?.DeepClone() ?? 1 });
            _generation++; _shown = null;
        });
    }
}

/// <summary>Mac `CareerSessionRef`：给弹窗用的场次包装，按 id 识别。</summary>
public sealed record CareerSessionRef(JsonNode Value)
{
    public string Id => Value.Text("id");
}

/// <summary>Mac `String.nonEmptyOr(_:)`：空串时取替代值。</summary>
public static class CareerStringExtensions
{
    public static string NonEmptyOr(this string value, string fallback) => value.Length == 0 ? fallback : value;
}
