using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 求职表单，对应 Mac `JobsBoardView.swift` 的 `CareerForm`：导入岗位、补录 / 推进阶段、排期、OC 与正式 Offer、分类、终止、删除等共用一个 880×780 弹窗
/// （左侧 272 宽点阵摘要、右侧 516 宽表单、88 高页脚）；待投递卡片拖到「筛选中」时是 480 宽的精简投递弹窗。
/// 每一步请求体在第一次提交时冻结，失败重试复用同一个 `client_request_id`，避免重复创建。
/// </summary>
public sealed partial class CareerForm : UserControl
{
    readonly JobAction _action;
    readonly IReadOnlyList<CareerApplication> _applications;
    readonly Action _completed;
    readonly Action _close;
    readonly Grid _root = new();

    string _kind = "";
    CareerApplication? _current;
    string _selectedExisting = "";
    DateTimeOffset _appliedAt = DateTimeOffset.Now;
    List<JsonNode> _resumes = [];
    string _selectedResume = "";
    string _company = "", _role = "", _description = "", _category = "", _city = "";
    string _stage = "interview", _label = "一面";
    int _round = 1;
    bool _slotSet, _deadlineSet;
    int _duration = 60, _planDuration = 60;
    string _interviewer = "", _prepNote = "";
    DateTimeOffset _ocAt = DateTimeOffset.Now;
    bool _ocAtSet;
    string _ocStartText = "", _ocNote = "";
    bool _reuseCurrentStage, _allowConflict;
    string _interviewMode = "video";
    DateTimeOffset _start = DateTimeOffset.Now, _end = DateTimeOffset.Now.AddSeconds(3600);
    bool _window, _planSet;
    DateTimeOffset _planStart = DateTimeOffset.Now;
    JsonNode? _createdSession;
    bool _savedPlan;
    JsonNode? _frozenPlan;
    string _meeting = "";
    string _reason = "user_withdrew";
    DateTimeOffset _offerReceived = DateTimeOffset.Now;
    bool _replySet;
    DateTimeOffset _replyDate = DateTimeOffset.Now;
    bool _startSet;
    DateTimeOffset _startDate = DateTimeOffset.Now;
    string _ocContact = "", _probation = "", _offerMaterials = "", _salaryDescription = "", _channel = "", _oralSalary = "";
    string _offerIntent = "none", _offerSalary = "", _offerBase = "", _currency = "CNY", _salaryPeriod = "month", _benefits = "", _notes = "";
    bool _busy;
    string? _error;
    bool _creationUnknown;
    string? _createdApplicationId;
    bool _savedSession;
    JsonNode? _savedStage;
    bool _staged;
    JsonNode? _frozenStage, _frozenOffer, _frozenSession;
    List<JsonNode> _sessions = [];
    JsonNode? _editingSession;
    string _sessionCommand = "";
    JsonNode? _commandPayload;
    bool _structuredOpen;

    CareerForm(JobAction action, IReadOnlyList<CareerApplication> applications, Action completed, Action close)
    {
        _action = action;
        _applications = applications;
        _completed = completed;
        _close = close;
        Content = _root;
        Loaded += async (_, _) => await StartAsync();
        Render();
    }

    /// <summary>打开表单（Mac `.sheet(item: $action)`）：精简投递 480 宽，其余 880×780。</summary>
    public static void Show(XamlRoot root, JobAction action, IReadOnlyList<CareerApplication> applications, Action completed)
    {
        CareerForm? form = null;
        V3Overlay? overlay = null;
        overlay = V3Overlay.Show(root, close =>
        {
            form = new CareerForm(action, applications, () => { close(); completed(); }, close);
            var frame = V3Dialog.Frame(form, action.Compact ? 480 : 880);
            if (!action.Compact) frame.Height = 780;
            return frame;
        }, dismissible: true);
    }

    static readonly Dictionary<string, string> Headings = new()
    {
        ["import"] = "导入岗位", ["arranged"] = "已有面试安排", ["stage"] = "添加求职阶段", ["category"] = "修改求职分类", ["terminate"] = "终止求职", ["delete"] = "删除岗位",
        ["detail"] = "求职详情", ["plugin"] = "安装浏览器插件", ["offer"] = "记录正式 Offer", ["apply"] = "记录投递", ["schedule-current"] = "安排时间", ["accept"] = "接受 Offer",
        ["decline"] = "婉拒 Offer", ["archive"] = "归档岗位", ["restore"] = "恢复岗位", ["notes"] = "编辑备注", ["schedule"] = "新建面试",
    };

    string Heading => Headings.TryGetValue(_kind, out var value) ? value : "岗位";
    bool NeedsStage => _kind is "stage" or "apply" or "schedule-current" or "arranged" or "schedule";
    bool Creation => _kind == "import" || (_kind is "arranged" or "schedule" && _selectedExisting.Length == 0);

    IReadOnlyList<string> StageOptions
    {
        get
        {
            if (_kind == "offer") return ["offer"];
            if (_staged || _reuseCurrentStage) return [_stage];
            var options = CareerStage.NextStages(_current ?? _applications.FirstOrDefault(a => a.Id == _selectedExisting));
            return _kind == "schedule" ? options.Where(o => o is "assessment" or "written_test" or "ai_interview" or "interview").ToArray() : options;
        }
    }

    bool ShowSchedule => _stage is "assessment" or "written_test" or "ai_interview" or "interview";
    bool StartsPending => _current?.Stage == "pending" || Creation;
    bool IsHR => _stage == "interview" && _label == "HR 面";
    bool IsWindow => _stage == "assessment" || (_stage == "written_test" && _window);
    /// <summary>Web 只在用户填了任何排期信息时才保存排期；仅排期的入口要求必须有。</summary>
    bool HasScheduleDetails => _slotSet || _deadlineSet || new[] { _meeting, _prepNote, _interviewer }.Any(x => x.Trim().Length > 0);
    bool ScheduleRequired => _kind is "schedule-current" or "schedule" or "arranged";
    DateTimeOffset PlanFinish => _planStart.AddMinutes(_planDuration);
    DateTimeOffset SessionStart => IsWindow && !_slotSet ? DateTimeOffset.Now : _start;
    /// <summary>发给接口的阶段类型：HR 面与 OC 有自己的类型。</summary>
    string StageType => _stage == "interview" && _label == "HR 面" ? "hr" : _stage == "offer" && _offerIntent == "none" ? "oc" : _stage;

    async Task StartAsync()
    {
        var action = _action;
        _kind = action.Kind; _current = action.Application; _stage = action.Stage; _label = action.Label;
        _round = Math.Max(1, action.Round ?? Math.Max(1, (action.Application?.Raw.Integer("current_round_no") ?? 0) + 1));
        if (_kind is "stage" or "apply" && _current?.Stage is not ("interview" or "ai_interview")) _label = "一面";
        if (_kind == "offer" && _current is { } offerApp)
        {
            _stage = "offer"; _offerIntent = "received"; _offerBase = offerApp.Raw.Text("offer_base_location"); _offerSalary = offerApp.Raw.Display("offer_salary");
            _currency = offerApp.Raw.Text("offer_salary_currency").NonEmpty() ?? "CNY";
            _salaryPeriod = offerApp.Raw.Text("offer_salary_period").NonEmpty() ?? "month"; _benefits = offerApp.Raw.Text("offer_benefits_description");
        }
        // 先取结构化字段；旧记录把这些值存成备注里的行
        var noteSource = _current?.Raw.Text("notes") ?? "";
        var raw = _current?.Raw;
        _channel = raw.Text("applied_channel").NonEmpty() ?? CareerNotes.Value("投递渠道", noteSource);
        _oralSalary = raw.Text("oc_salary_text").NonEmpty() ?? CareerNotes.Value("口头薪酬", noteSource);
        _ocContact = raw.Text("oc_contact");
        _probation = raw.Text("offer_probation").NonEmpty() ?? CareerNotes.Value("试用期", noteSource);
        _offerMaterials = CareerNotes.Value("Offer 材料", noteSource); _salaryDescription = CareerNotes.Value("薪酬说明", noteSource);
        if (CareerFormat.OfferDate(raw.Text("offer_received_on")) is { } received) _offerReceived = received;
        if (CareerFormat.OfferDate(raw.Text("offer_reply_due_on")) is { } reply) { _replySet = true; _replyDate = reply; }
        if (CareerFormat.OfferDate(raw.Text("offer_start_on")) is { } begin) { _startSet = true; _startDate = begin; }
        _category = action.Application?.Category ?? "";
        if (action.Start is { } seed) { _start = seed; _slotSet = true; }
        if (action.End is { } seedEnd) { _end = seedEnd; if (action.Start is { } from && seedEnd > from) _duration = Math.Max(1, (int)((seedEnd - from).TotalSeconds / 60)); }
        _ocStartText = raw.Text("oc_start_text"); _ocNote = raw.Text("oc_note");
        if (CareerApplication.Date(raw.Text("oc_communicated_at")) is { } oc) { _ocAt = oc; _ocAtSet = true; }
        if (_kind == "schedule-current" && _current is { } scheduling) { _reuseCurrentStage = true; _stage = scheduling.Stage; _label = scheduling.StageLabel; }
        _window = _stage == "assessment";
        if (_kind == "notes") _notes = _current?.Raw.Text("notes") ?? "";
        Render();
        if (_kind == "detail") await LoadDetailAsync();
        else if (NeedsStage)
        {
            try { _resumes = (await RequestAsync("/api/resumes")).Items("resumes"); }
            catch (Exception error) { _error = "简历列表暂不可用，仍可不关联简历继续。 " + Explain(error); }
            Render();
        }
    }

    void ChangeSelectedExisting(string id)
    {
        _selectedExisting = id;
        if (_kind == "schedule" && _applications.FirstOrDefault(a => a.Id == id) is { } chosen)
        {
            _reuseCurrentStage = ReusableCurrent(chosen);
            _stage = _reuseCurrentStage ? chosen.Stage : "interview"; _label = _reuseCurrentStage ? chosen.StageLabel : "一面";
            _round = Math.Max(1, chosen.Raw.Get("current_round_no").Number() is { } n ? (int)n : 1);
        }
        else _reuseCurrentStage = false;
        Render();
    }

    void ChangeReuse(bool reuse)
    {
        _reuseCurrentStage = reuse;
        if (_kind == "schedule" && _applications.FirstOrDefault(a => a.Id == _selectedExisting) is { } chosen)
        {
            _stage = reuse ? chosen.Stage : "interview";
            _label = reuse ? chosen.StageLabel : "一面";
            _round = reuse ? Math.Max(1, chosen.Raw.Get("current_round_no").Number() is { } n ? (int)n : 1) : Math.Max(1, chosen.Raw.Integer("current_round_no") + 1);
        }
        Render();
    }

    static bool ReusableCurrent(CareerApplication chosen) =>
        chosen.Raw.Get("current_stage").Text("id").Length > 0 && chosen.Raw.Text("stage_state") == "awaiting_schedule"
        && chosen.Stage is "assessment" or "written_test" or "ai_interview" or "interview";

    /// <summary>只有没有独立字段的值留在备注里；旧记录里过期的日期行会被去掉。</summary>
    string OfferNotes => CareerNotes.Merge(new Dictionary<string, string>
    {
        ["收到日期"] = "", ["回复截止"] = "", ["预计入职"] = "", ["试用期"] = "", ["Offer 材料"] = _offerMaterials, ["薪酬说明"] = _salaryDescription,
    }, _current?.Raw.Text("notes") ?? "");

    static string CalendarDay(DateTimeOffset date) => date.ToLocalTime().ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
    static string Iso(DateTimeOffset date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);

    static string DefaultRound(CareerApplication? app) =>
        app is null || app.Raw.Text("current_stage_type") != "interview" ? "一面" : JobsBoardView.RoundLabel(app.Raw.Integer("current_round_no") + 1);

    string DialogTitle => _kind == "stage" ? "添加下一阶段" : _kind == "apply" ? (StartsPending ? "记录投递" : Heading) : Heading;

    string StageName
    {
        get
        {
            if (_stage == "offer") return _offerIntent == "none" ? "OC" : "Offer";
            if (_stage == "interview") return IsHR ? "HR 面" : "面试";
            return _stage == "screening" ? "筛选" : CareerStage.Label(_stage);
        }
    }

    string CurrentName => _stage == "interview" && !IsHR ? (_label.Length == 0 ? "面试" : _label) : StageName;

    static readonly Dictionary<string, string> FixedSubmit = new()
    {
        ["offer"] = "记录 Offer", ["accept"] = "确认接受", ["decline"] = "确认婉拒", ["schedule-current"] = "保存安排", ["terminate"] = "终止求职", ["category"] = "保存分类",
    };

    string SubmitLabel
    {
        get
        {
            if (_kind == "delete") return "确认删除";
            if (_staged) return "重试剩余步骤";
            if (FixedSubmit.TryGetValue(_kind, out var label)) return label;
            if (!NeedsStage) return "保存";
            if (StartsPending) return "确认投递";
            if (_stage == "offer") return _offerIntent == "none" ? "记录 OC" : "记录 Offer";
            return "添加" + StageName;
        }
    }

    string FooterHint => !NeedsStage || _stage is "offer" or "screening" ? "" : IsWindow ? "快速选择从现在开始算" : "保存后可在面试日程中调整";

    static string? ShortDay(DateTimeOffset? date) => date?.ToLocalTime().ToString("MM-dd", System.Globalization.CultureInfo.InvariantCulture);
    static string ListDateTime(DateTimeOffset date) => date.ToLocalTime().ToString("M月d日 HH:mm", System.Globalization.CultureInfo.InvariantCulture);

    // MARK: 请求

    static Task<JsonNode> RequestAsync(string path, string method = "GET", JsonObject? fields = null, Dictionary<string, string>? query = null) =>
        App.Session.Api.CareerRequestAsync(path, method, query, fields);

    static string Explain(Exception error)
    {
        if (error is OperationCanceledException) return "操作已取消。";
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) return "登录已失效，请关闭并重新登录。";
        if (error is ApiException api)
        {
            var status = (int)api.Status;
            if (status == 409) return $"服务端状态发生变化或操作冲突（{api.Code}）。请刷新后重试；已保存步骤不会回滚。";
            if (status == 403) return "当前服务尚未开放桌面岗位权限，请更新服务端后重试。";
            return $"操作失败（{api.Code}），你的输入已保留。";
        }
        return "连接失败，输入已保留。可重试；如已保存部分步骤，请先确认服务端状态。";
    }

    async Task LoadDetailAsync()
    {
        if (_current is not { } current) return;
        _busy = true; Render();
        try
        {
            var detail = await RequestAsync($"/api/job-applications/{current.Id}");
            _current = new CareerApplication(detail["application"] ?? new JsonObject());
            _notes = detail["application"].Text("notes");
            if (detail["application"].Display("job_description_id") is { Length: > 0 } jobId)
            {
                var job = await RequestAsync($"/api/job-descriptions/{jobId}");
                _description = job["job_description"].Text("description");
            }
            var page = await RequestAsync("/api/interview-sessions", query: new() { ["application_id"] = current.Id, ["limit"] = "500", ["include_archived"] = "true" });
            _sessions = page.Items("items");
        }
        catch (Exception error) { _error = Explain(error); }
        _busy = false; Render();
    }

    async Task SaveSessionAsync(JsonNode item)
    {
        if (_sessionCommand is "reschedule" or "answer-plan" && _end <= _start) { _error = "结束时间须晚于开始时间。"; Render(); return; }
        _busy = true; _error = null; Render();
        try
        {
            if (_commandPayload is null)
            {
                var fields = new JsonObject { ["base_lock_version"] = item["lock_version"]?.DeepClone() ?? 1 };
                if (_sessionCommand == "reschedule") { fields["start_at"] = Iso(_start); fields["end_at"] = Iso(_end); fields["timezone"] = JobsBoardView.TimeZoneId(); }
                else if (_sessionCommand == "answer-plan") { fields["answer_plan_start_at"] = Iso(_start); fields["answer_plan_end_at"] = Iso(_end); }
                _commandPayload = fields;
            }
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{item.Text("id")}/{_sessionCommand}", _sessionCommand == "answer-plan" ? "PUT" : "POST", null, _commandPayload.DeepClone());
            _editingSession = null; _commandPayload = null;
            await LoadDetailAsync();
        }
        catch (Exception error) { _error = Explain(error); }
        _busy = false; Render();
    }

    async Task ChooseImageAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        if (await picker.PickSingleFileAsync() is not { } file) return;
        try
        {
            var properties = await file.GetBasicPropertiesAsync();
            if (properties.Size > 10 * 1024 * 1024) throw new InvalidDataException();
            var data = await File.ReadAllBytesAsync(file.Path);
            await ParseDraftAsync(data, file.FileType.ToLowerInvariant() == ".png" ? "image/png" : "image/jpeg");
        }
        catch (Exception) { _error = "截图读取失败，仅支持 10 MiB 以内的 PNG/JPEG。"; Render(); }
    }

    async Task ParseDraftAsync(byte[]? image = null, string type = "image/png")
    {
        _busy = true; _error = null; Render();
        try
        {
            var body = image is null ? new JsonObject { ["text"] = _description } : new JsonObject { ["image_base64"] = Convert.ToBase64String(image), ["content_type"] = type };
            var result = await RequestAsync("/api/job-descriptions/parse-draft", "POST", body);
            var draft = result["draft"] ?? result["job_description"] ?? result;
            _company = draft.Text("company_name"); _role = draft.Text("job_title"); _city = draft.Text("work_city"); _category = draft.Text("employment_type");
            if (draft.Text("description").Length > 0) _description = draft.Text("description");
        }
        catch (Exception error) { _error = Explain(error); }
        _busy = false; Render();
    }

    async Task SaveOfferAsync(CareerApplication app)
    {
        var probation = _probation.Trim();
        _frozenOffer ??= new JsonObject
        {
            ["base_lock_version"] = app.LockVersion, ["received_on"] = CalendarDay(_offerReceived),
            ["reply_due_on"] = _replySet ? CalendarDay(_replyDate) : null, ["start_on"] = _startSet ? CalendarDay(_startDate) : null,
            ["probation"] = probation.Length == 0 ? null : probation, ["base_location"] = _offerBase.Length == 0 ? null : _offerBase,
            ["salary"] = _offerSalary.Length == 0 ? null : double.Parse(_offerSalary, System.Globalization.CultureInfo.InvariantCulture),
            ["salary_currency"] = _offerSalary.Length == 0 ? null : _currency, ["salary_period"] = _offerSalary.Length == 0 ? null : _salaryPeriod,
            ["benefits_description"] = _benefits.Length == 0 ? null : _benefits, ["notes"] = OfferNotes,
        };
        var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{app.Id}/offer", "POST", null, _frozenOffer.DeepClone());
        _current = new CareerApplication(result["application"] ?? new JsonObject());
    }

    async Task SaveNotesAsync()
    {
        if (_current is not { } current) return;
        _busy = true; _error = null; Render();
        try
        {
            var result = await RequestAsync($"/api/job-applications/{current.Id}", "PUT", new JsonObject { ["base_lock_version"] = current.LockVersion, ["notes"] = _notes });
            _current = new CareerApplication(result["application"] ?? new JsonObject());
        }
        catch (Exception error) { _error = Explain(error); }
        _busy = false; Render();
    }
}
