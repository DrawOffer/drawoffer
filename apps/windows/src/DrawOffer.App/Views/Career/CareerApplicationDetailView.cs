using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>Mac `CareerButtonStyle`：12px 中粗、左右 16、默认 34 高、圆角 6；主按钮黑底白字，次按钮白底 #E4E4E0 边；按下 0.7。</summary>
public sealed class CareerButton : BorderControl
{
    public CareerButton(string title, Action action, bool primary = false, double radius = 6, double height = 34)
    {
        Child = Sans(title, 12, primary ? V3.White : Hex(0x1D1D1B), Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Padding = new Thickness(16, 0, 16, 0);
        Height = height;
        CornerRadius = new CornerRadius(radius);
        Background = Brush(primary ? Hex(0x1D1D1B) : V3.White);
        BorderBrush = Brush(primary ? Clear : Hex(0xE4E4E0));
        BorderThickness = new Thickness(1);
        AutomationProperties.SetName(this, title);
        PointerPressed += (_, e) => { Opacity = 0.7; e.Handled = true; };
        PointerReleased += (_, e) => { Opacity = 1; e.Handled = true; action(); };
        PointerExited += (_, _) => Opacity = 1;
        ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.Hand);
    }
}

/// <summary>
/// Mac `CareerIcon`：读 `Resources/Career/&lt;name&gt;.png`，Windows 打包在 `ms-appx:///Assets/Career/&lt;name&gt;.png`。
/// template 时按 alpha 单色着色（Swift `.renderingMode(.template)`），颜色取 tint（默认 V3.Txt）；读屏忽略。
/// </summary>
public static class CareerIcon
{
    public static FrameworkElement Make(string name, double size = 20, bool template = false, Color? tint = null)
    {
        var uri = new Uri($"ms-appx:///Assets/Career/{name}.png");
        FrameworkElement icon = template
            ? new BitmapIcon { UriSource = uri, ShowAsMonochrome = true, Foreground = Brush(tint ?? Txt) }
            : new Image { Source = new BitmapImage(uri), Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform };
        icon.Width = size;
        icon.Height = size;
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return icon;
    }
}

/// <summary>
/// 投递详情（Windows 稿 07 页，Mac `CareerApplicationDetailView.swift`）：「这一步」+ 右侧内容 + 全程时间线；
/// 阶段详情、复盘报告、岗位详情、资料与面试记录是这里的下级页面。
/// </summary>
public sealed partial class CareerApplicationDetailView : UserControl
{
    readonly CareerApplication _application;
    readonly Action _back;
    readonly Action<string, CareerApplication> _perform;
    /// <summary>从资料库「求职进程」进来时直接停在资料页，返回回到资料库。</summary>
    readonly bool _libraryMaterials;
    /// <summary>Mac `router?.jump(.application(id))`：资料库入口里「打开求职进度 ↗」；Windows 外壳还没有这个路由，由调用方传入。</summary>
    readonly Action? _openApplication;

    abstract record Route
    {
        public sealed record Stage(string Id) : Route;
        public sealed record Report(string Id, bool FromStage = false) : Route;
        public sealed record Job(string Id) : Route;
        public sealed record Materials(string? Id) : Route;
        public sealed record Record(string Id, bool Paste, string? FromMaterials) : Route;
    }

    sealed record SplitJob(bool Running, string? Error);

    Route? _route;
    JsonNode? _current;
    List<JsonNode> _sessions = [];
    string? _error;
    string? _notice;
    bool _loading = true;
    bool _busy;
    string? _jobDescription;
    DateTimeOffset _now = Beijing.Now;
    string? _viewKey;
    Dictionary<string, JsonNode> _details = [];
    string? _prepBusy;
    readonly Dictionary<string, SplitJob> _splits = [];
    /// <summary>Swift `.task(id: refreshed)`：每次刷新或页面重新出现都重读；旧的读取结果作废。</summary>
    int _generation;
    string? _shown;

    JsonNode Raw => _current ?? _application.Raw;
    CareerApplication Item => new CareerApplication(Raw).IncludingSessions(_sessions);
    CareerDetailModel Model => new(Raw, _sessions, _now);
    bool Active => Raw.Text("lifecycle_status") != "terminated" && Raw.Text("status") == "active" && Raw.Text("archived_at").Length == 0;
    CareerDeck Deck => new(Raw, _sessions, _now);

    public CareerApplicationDetailView(CareerApplication application, Action back, Action<string, CareerApplication> perform, bool libraryMaterials = false, Action? openApplication = null)
    {
        _application = application;
        _back = back;
        _perform = perform;
        _libraryMaterials = libraryMaterials;
        _openApplication = openApplication;
        KeyDown += (_, e) =>
        {
            // `.onExitCommand`：Esc 回到当前这一站
            if (e.Key == Windows.System.VirtualKey.Escape && _route is null && _viewKey is not null) { e.Handled = true; _viewKey = null; Render(); }
        };
        Render();
    }

    /// <summary>`refreshed = UUID()`。</summary>
    void Refresh()
    {
        _generation++;
        _shown = null;
        Render();
    }

    void Go(Route? route)
    {
        _route = route;
        Render();
    }

    void Render()
    {
        var route = _route ?? (_libraryMaterials ? new Route.Materials(null) : null);
        switch (route)
        {
            case Route.Stage stage:
                Content = new CareerStageDetailView(stage.Id, () => { _route = null; Refresh(); }, () => Go(new Route.Report(stage.Id, true)));
                _shown = null;
                return;
            case Route.Report report:
                Content = new CareerReviewReportView(report.Id, () => { if (report.FromStage) Go(new Route.Stage(report.Id)); else { _route = null; Refresh(); } });
                _shown = null;
                return;
            case Route.Job job:
                Content = new JobDetailView(job.Id, Raw, () => { _route = null; Refresh(); }, _back);
                _shown = null;
                return;
            case Route.Materials materials:
                Content = MaterialsPage(materials.Id);
                Appear("materials");
                return;
            case Route.Record record:
            {
                var deck = Deck;
                if (deck.Stations.FirstOrDefault(x => x.Session?.Text("id") == record.Id) is { } station)
                {
                    var session = _details.TryGetValue(record.Id, out var detail) && detail.Get("session") is { } fresh ? fresh : station.Session ?? JsonValue.Create<string?>(null)!;
                    var from = record.FromMaterials;
                    _splits.TryGetValue(record.Id, out var split);
                    Content = new CareerRecordPage(Raw, station, session, record.Paste ? CareerRecordPage.Mode.Paste : CareerRecordPage.Mode.Record,
                        split?.Running == true, split?.Error, from is null ? "求职进度" : "资料",
                        () => Go(from is null ? null : new Route.Materials(from)),
                        text => { StartSplit(record.Id, text); Go(from is null ? null : new Route.Materials(from)); },
                        () => Go(new Route.Stage(record.Id)));
                    _shown = null;
                    return;
                }
                break;
            }
        }
        Content = ProgressPage();
        Appear("progress");
    }

    /// <summary>进度页 / 资料页出现时读取（Swift 两处 `.task(id: refreshed)`）。</summary>
    void Appear(string page)
    {
        var key = page + ":" + _generation;
        if (_shown == key) return;
        _shown = key;
        _ = LoadAsync(_generation);
    }

    UIElement MaterialsPage(string? id)
    {
        var splitting = _splits.Where(x => x.Value.Running).Select(x => x.Key).ToHashSet();
        return new CareerMaterialsPage(Raw, Deck, _details, id, splitting,
            () => { if (_libraryMaterials) _back(); else Go(null); },
            (session, mode) => Go(new Route.Record(session, mode == CareerRecordPage.Mode.Paste, session)),
            session => Go(new Route.Stage(session.Text("id"))),
            session => Go(new Route.Stage(session.Text("id"))),
            session => OpenAdd(session, CareerAddContentSheet.Mode.Upload),
            session => OpenAdd(session, CareerAddContentSheet.Mode.Library),
            () => { if (Raw.Text("resume_id").Length > 0) WorkspaceShell.Current.EditResume(Raw.Text("resume_id")); },
            OpenJob,
            _libraryMaterials, _libraryMaterials ? _openApplication : null);
    }

    /// <summary>添加面试 / 笔试内容（Mac `.sheet(item: adding)`）。</summary>
    void OpenAdd(JsonNode session, CareerAddContentSheet.Mode mode)
    {
        var kind = session.Text("stage_type") is "written_test" or "assessment" ? "笔试" : "面试";
        V3Overlay? overlay = null;
        overlay = V3Overlay.Show(XamlRoot, close => new CareerAddContentSheet(session, kind, mode, close, () => { overlay?.Close(); Refresh(); }));
    }

    /// <summary>粘贴文字拆成问题（Web `recordSplit.ts`）：回到上一页后在后台跑，拆好直接存成这一站的面试记录。</summary>
    void StartSplit(string id, string text)
    {
        if (_splits.TryGetValue(id, out var job) && job.Running || text.Length == 0) return;
        _splits[id] = new SplitJob(true, null);
        _ = Run();
        async Task Run()
        {
            try
            {
                var draft = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{id}/record:structure", "POST", [], new JsonObject { ["source"] = "text", ["text"] = text });
                var latest = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{id}", "GET", [], null);
                var markdown = InterviewRecord.Serialize(InterviewRecord.Draft(draft));
                await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{id}", "PUT", [],
                    new JsonObject { ["questions_markdown"] = markdown.Length == 0 ? null : markdown, ["base_lock_version"] = latest.Get("session").Get("lock_version")?.DeepClone() ?? 1 });
                _splits.Remove(id);
                Refresh();
            }
            catch (Exception error)
            {
                Unauthorized(error);
                var code = (error as ApiException)?.Code;
                _splits[id] = new SplitJob(false, code == "INTERVIEW_QUESTIONS_NOT_FOUND" ? "这段文字里没找到面试问题，可以补几句再拆。" : CareerErrors.Message(error));
                Render();
            }
        }
    }

    async Task SavePrep(JsonNode session, JsonArray items)
    {
        var id = session.Text("id");
        _prepBusy = id; Render();
        var lock_ = (_details.TryGetValue(id, out var detail) ? detail.Get("session").Get("lock_version") : null) ?? session.Get("lock_version");
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{id}", "PUT", [], new JsonObject { ["prep_items"] = items, ["base_lock_version"] = lock_?.DeepClone() ?? 1 });
            _prepBusy = null;
            Refresh();
        }
        catch (Exception error) { Unauthorized(error); _notice = CareerErrors.Message(error); }
        finally { _prepBusy = null; Render(); }
    }

    static void Unauthorized(Exception error)
    {
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
    }

    async Task LoadAsync(int generation)
    {
        _loading = true; _error = null; _now = Beijing.Now;
        var id = _application.Id;
        try
        {
            var detail = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{id}", "GET", [], null);
            var all = new List<JsonNode>();
            var cursor = "";
            var seen = new HashSet<string>();
            do
            {
                var query = new Dictionary<string, string> { ["application_id"] = id, ["limit"] = "500", ["include_archived"] = "true" };
                if (cursor.Length > 0) query["cursor"] = cursor;
                var page = await App.Session.Api.CareerRequestAsync("/api/interview-sessions", "GET", query, null);
                all.AddRange(page.Items("items"));
                cursor = page.Text("next_cursor");
                if (cursor.Length > 0 && !seen.Add(cursor)) throw new InvalidOperationException();
            } while (cursor.Length > 0);
            if (generation != _generation) return;
            var app = detail.Get("application") ?? JsonValue.Create<string?>(null)!;
            _current = app.Get("id") is null ? null : app;
            _sessions = all;
            var loaded = new Dictionary<string, JsonNode>();
            foreach (var session in all.Where(x => x.Text("status") != "cancelled"))
            {
                try { loaded[session.Text("id")] = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{session.Text("id")}", "GET", [], null); }
                catch (Exception error) when (error is not OperationCanceledException) { }
            }
            if (generation != _generation) return;
            _details = loaded;
            if (Raw.Text("job_description_id") is { Length: > 0 } jobId)
            {
                try { _jobDescription = (await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{jobId}", "GET", [], null)).Get("job_description").Text("description").NonEmptyOr("暂无岗位描述"); }
                catch (Exception error) when (error is not OperationCanceledException) { }
            }
        }
        catch (OperationCanceledException) { return; }
        catch (ApiException error) when (error.Status == System.Net.HttpStatusCode.Unauthorized) { App.Session.ReportAuthenticationFailure(); _error = "登录已失效，请重新登录。"; }
        catch (Exception) { _error = "求职记录读取失败，请重试。"; }
        if (generation != _generation) return;
        _loading = false;
        Render();
        _ = LoadPrices();
        Poll();
    }
}
