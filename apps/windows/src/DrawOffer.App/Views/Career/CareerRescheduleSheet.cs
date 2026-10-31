using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>修改安排（Mac `CareerRescheduleSheet`）：改一场已安排场次的时间（或开放窗口笔试的窗口）。</summary>
public sealed class CareerRescheduleSheet : UserControl
{
    readonly JsonNode _session;
    readonly Action _close;
    readonly Action _saved;
    readonly CalendarDatePicker _startDate = new() { Header = "开始时间" };
    readonly TimePicker _startTime = new() { ClockIdentifier = "24HourClock" };
    readonly CalendarDatePicker _endDate = new() { Header = "结束时间" };
    readonly TimePicker _endTime = new() { ClockIdentifier = "24HourClock" };
    bool _busy;
    string? _error;
    JsonNode? _payload;

    public CareerRescheduleSheet(JsonNode session, Action close, Action saved)
    {
        _session = session;
        _close = close;
        _saved = saved;
        var start = CareerApplication.Date(session.Text("start_at")) ?? DateTimeOffset.Now;
        var end = CareerApplication.Date(session.Text("end_at")) ?? start.AddHours(1);
        Set(_startDate, _startTime, start);
        Set(_endDate, _endTime, end);
        Render();
    }

    static void Set(CalendarDatePicker date, TimePicker time, DateTimeOffset value)
    {
        var local = TimeZoneInfo.ConvertTime(value, TimeZoneInfo.Local);
        date.Date = local.Date;
        time.Time = local.TimeOfDay;
    }

    static DateTimeOffset Read(CalendarDatePicker date, TimePicker time)
    {
        var day = (date.Date ?? DateTimeOffset.Now).Date;
        var local = DateTime.SpecifyKind(day + time.Time, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local));
    }

    void Render()
    {
        var locked = _payload is not null;
        foreach (var control in new Control[] { _startDate, _startTime, _endDate, _endTime }) control.IsEnabled = !locked;
        var content = new List<UIElement>
        {
            HStack(8, Detach(_startDate), Detach(_startTime).Align(v: VerticalAlignment.Bottom)),
            HStack(8, Detach(_endDate), Detach(_endTime).Align(v: VerticalAlignment.Bottom)),
        };
        if (_error is { } error) content.Add(Sans(error, 12, CareerPalette.Red).Wrap());
        var cancel = new CareerAction("取消", _close, large: true) { Enabled = !_busy };
        var save = new CareerAction(_busy ? "正在保存…" : _payload is null ? "保存" : "重试", () => _ = Save(), CareerAction.Kind.Primary, large: true) { Enabled = !_busy };
        Content = CareerSheet.Make("修改安排", 520, content, [cancel, save], _session.Text("stage_label") + " · " + CareerSessions.Line(_session));
    }

    /// <summary>重建时把输入控件从旧父级上取下来再放进新布局。</summary>
    static T Detach<T>(T element) where T : FrameworkElement
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        return element;
    }

    async Task Save()
    {
        var start = Read(_startDate, _startTime);
        var end = Read(_endDate, _endTime);
        if (end <= start) { _error = "结束时间须晚于开始时间。"; Render(); return; }
        _busy = true; _error = null; Render();
        // 响应丢失时保留同一请求，重试不会变成另一次修改
        _payload ??= new JsonObject
        {
            ["base_lock_version"] = _session.Get("lock_version")?.DeepClone() ?? 1,
            ["start_at"] = start.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            ["end_at"] = end.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            ["timezone"] = TimeZoneInfo.TryConvertWindowsIdToIanaId(TimeZoneInfo.Local.Id, out var iana) ? iana : TimeZoneInfo.Local.Id,
        };
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}/reschedule", "POST", [], _payload.DeepClone());
            _busy = false;
            _saved();
            return;
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (error is ApiException api && (int)api.Status is 400 or 409 or 422) _payload = null;
            _error = CareerErrors.Message(error);
        }
        _busy = false;
        Render();
    }
}
