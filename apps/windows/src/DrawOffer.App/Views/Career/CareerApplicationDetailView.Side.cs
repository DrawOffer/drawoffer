using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>投递详情里会改动数据的请求（Mac `toggleFavorite` / `update` / `reopen` / `decide` / `generatePrep` / `retryTranscription` / `loadPrices`）。</summary>
public sealed partial class CareerApplicationDetailView
{
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

    /// <summary>09.03 接受或婉拒 Offer：结束这条投递。</summary>
    Task DecideAsync(string decision) => Mutate(async () =>
    {
        await App.Session.Api.CareerRequestAsync($"/api/job-applications/{_application.Id}/close", "POST", [],
            LockBody(new JsonObject { ["status"] = "closed", ["offer_status"] = decision }));
        _generation++; _shown = null;
    });

    async Task GeneratePrep(JsonNode session)
    {
        _prepBusy = session.Text("id"); Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{session.Text("id")}/prep-items:generate", "POST", [], null);
            _generation++; _shown = null;
        }
        catch (Exception error) { Unauthorized(error); _notice = CareerErrors.Message(error); }
        finally { _prepBusy = null; Render(); }
    }

    Task RetryTranscription(JsonNode session, string datasetId) => Mutate(async () =>
    {
        await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{session.Text("id")}/transcriptions/{datasetId}:retry", "POST", [], null);
        _generation++; _shown = null;
    });

    /// <summary>生成复盘、准备清单的固定积分（按钮后的小字）。</summary>
    async Task LoadPrices()
    {
        if (_pricesLoaded) return;
        _pricesLoaded = true;
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/billing/feature-prices", "GET", [], null);
            var items = result.Items("items");
            string? Fixed(string code)
            {
                var price = items.FirstOrDefault(x => x.Text("featureCode") == code);
                if (price?.Text("priceMode") != "fixed") return null;
                var raw = price.Get("unitPoints");
                double? points = raw.Number() ?? (raw is System.Text.Json.Nodes.JsonValue text && text.TryGetValue<string>(out var str) && double.TryParse(str, out var parsed) ? parsed : null);
                if (points is not { } value) return null;
                return value == Math.Round(value) ? $"{(long)value}" : $"{value}";
            }
            _reviewCost = Fixed("interview_review") is { } review ? review + " 积分" : null;
            _prepCost = Fixed("interview_prep") is { } prep ? "消耗 " + prep + " 积分" : null;
            Render();
        }
        catch (Exception) { _pricesLoaded = false; }
    }

    /// <summary>复盘生成中或录音转写中。</summary>
    bool Waiting => _sessions.Any(x => x.Text("review_status") == "generating")
        || _details.Values.Any(x => x.Get("session").Items("transcriptions").Any(t => t.Text("status") is "queued" or "running"));

    bool _polling;

    /// <summary>复盘或转写在后台跑：每 10 秒刷新，直到落定；离开页面就停。</summary>
    async void Poll()
    {
        if (_polling || !Waiting) return;
        _polling = true;
        try
        {
            while (Waiting && IsLoaded)
            {
                await Task.Delay(TimeSpan.FromSeconds(10));
                if (Waiting && IsLoaded && _route is null) Refresh();
            }
        }
        finally { _polling = false; }
    }
}

/// <summary>Mac `String.nonEmptyOr(_:)`：空串时取替代值。</summary>
public static class CareerStringExtensions
{
    public static string NonEmptyOr(this string value, string fallback) => value.Length == 0 ? fallback : value;
}
