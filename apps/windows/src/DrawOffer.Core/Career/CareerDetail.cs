using System.Text.Json.Nodes;
namespace DrawOffer.Core.Models;

/// <summary>共用色调。</summary>
public enum CareerTone { Blue, Green, Orange, Gray, Red, Dark }

public readonly record struct CareerChip(string Label, CareerTone Tone);

public enum CareerDetailStepState { Done, Current, Next, Failed, Offer, Todo }

public sealed record CareerDetailStep(string Id, string Label, string Meta, CareerDetailStepState State);

/// <summary>「下一步」卡片左侧的方块：日期或状态。</summary>
public abstract record CareerDetailTile
{
    public sealed record Date(string Head, string Day, string Foot) : CareerDetailTile;
    public sealed record Status(string Title, string Sub, CareerTone Tone) : CareerDetailTile;
}

public enum CareerDetailAction { RecordApplied, Advance, Schedule, RecordReview, AnswerPlan, Reschedule, CancelSession, RecordOffer, AcceptOffer, EditOffer, DeclineOffer, ViewReview }

public sealed record CareerDetailButton(CareerDetailAction Action, string Label, bool Danger = false, bool Dark = true);

public sealed record CareerDetailNext(string Lead, CareerDetailTile Tile, IReadOnlyList<CareerChip> Chips, string Title, string Detail, string? Hint, CareerDetailButton? Primary, IReadOnlyList<CareerDetailButton> Secondary);

public sealed record CareerHistoryItem(string Id, string Date, string Title, CareerChip Chip, string Detail, CareerTone? Dot, CareerTone? Highlight, string? SessionId);

public sealed record CareerInfoRow(string Label, string Value, CareerTone? Tone = null);

public sealed record CareerOfferCard(string Title, string Action, IReadOnlyList<CareerInfoRow> Rows);

public static class CareerFormat
{
    internal static string Two(int value) => CareerDeckFormat.Two(value);

    public static string MonthDay(string raw, TimeZoneInfo? zone = null)
    {
        if (CareerApplication.Date(raw) is not { } date) return "—";
        var local = SwiftCalendar.Local(date, zone ?? Beijing.Zone);
        return Two(local.Month) + "." + Two(local.Day);
    }

    public static string Clock(string raw, TimeZoneInfo? zone = null)
    {
        if (CareerApplication.Date(raw) is not { } date) return "—";
        var local = SwiftCalendar.Local(date, zone ?? Beijing.Zone);
        return Two(local.Hour) + ":" + Two(local.Minute);
    }

    public static string Range(string start, string end, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        if (CareerApplication.Date(start) is not { } s || CareerApplication.Date(end) is not { } e) return "—";
        return SwiftCalendar.SameDay(s, e, tz)
            ? $"{MonthDay(start, tz)} {Clock(start, tz)}–{Clock(end, tz)}"
            : $"{MonthDay(start, tz)} {Clock(start, tz)} – {MonthDay(end, tz)} {Clock(end, tz)}";
    }

    /// <summary>Offer 日期是日历日期（`YYYY-MM-DD`），不经过 UTC 换算。</summary>
    public static DateTimeOffset? OfferDate(string raw, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        // Swift `split(separator:)` 省略空段，`compactMap { Int($0) }` 丢掉非数字段。
        var parts = raw.Split('-', StringSplitOptions.RemoveEmptyEntries).Select(SwiftText.Int).OfType<int>().ToArray();
        if (SwiftText.Count(raw) != 10 || parts.Length != 3 || parts[0] < 1000) return null;
        if (parts[1] is < 1 or > 12 || parts[2] < 1 || parts[0] > 9999 || parts[2] > DateTime.DaysInMonth(parts[0], parts[1])) return null;
        return SwiftCalendar.Date(parts[0], parts[1], parts[2], tz);
    }

    public static string? OfferDay(string raw, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        if (OfferDate(raw, tz) is not { } date) return null;
        var local = SwiftCalendar.Local(date, tz);
        return Two(local.Month) + "." + Two(local.Day);
    }

    public static string? OfferLong(string raw, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        if (OfferDate(raw, tz) is not { } date) return null;
        var local = SwiftCalendar.Local(date, tz);
        return $"{local.Year}年{local.Month}月{local.Day}日";
    }

    /// <summary>两天之间相差的日历天数（按当天零点）。</summary>
    public static int Days(DateTimeOffset start, DateTimeOffset end, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        return SwiftCalendar.Days(SwiftCalendar.StartOfDay(start, tz), SwiftCalendar.StartOfDay(end, tz), tz);
    }
}

public static class CareerSessions
{
    /// <summary>时间决定是否完成：已过结束时间的已安排场次算作完成。</summary>
    public static string EffectiveStatus(JsonNode session, DateTimeOffset? now = null)
    {
        var status = session.Text("status");
        if (status == "scheduled" && CareerApplication.Date(session.Text("end_at")) is { } end && end <= (now ?? Beijing.Now)) return "completed";
        return status;
    }

    public static JsonNode WithEffectiveStatus(JsonNode session, DateTimeOffset now)
    {
        if (session is not JsonObject) return session;
        var copy = session.DeepClone();
        copy["status"] = EffectiveStatus(session, now);
        return copy;
    }

    public static string ModeLabel(JsonNode session) => session.Text("mode") switch { "video" => "视频面试", "onsite" => "现场", "phone" => "电话", _ => "其他方式" };

    /// <summary>阶段详情的说法：会议平台和现场地点都算在方式里。</summary>
    public static string ModeText(JsonNode session) => session.Text("mode") switch
    {
        "video" => SwiftText.Contains(session.Text("meeting_url"), "feishu") ? "飞书视频" : "视频面试",
        "onsite" => session.Text("location").Length == 0 ? "现场" : "现场 · " + session.Text("location"),
        "phone" => "电话",
        _ => "其他方式",
    };

    internal static string? Interviewer(JsonNode session, bool withRole)
    {
        var name = session.Text("interviewer_name");
        if (name.Length == 0) return null;
        if (withRole) return "面试官 " + name;
        var title = session.Text("interviewer_title");
        return title.Length == 0 ? name : $"{name}（{title}）";
    }

    public static string Line(JsonNode session, bool withRole = false, TimeZoneInfo? zone = null)
    {
        if (session.Text("schedule_kind") == "open_window")
        {
            string planStart = session.Text("answer_plan_start_at"), planEnd = session.Text("answer_plan_end_at");
            var plan = planStart.Length > 0 && planEnd.Length > 0 ? " · 我的作答计划 " + CareerFormat.Range(planStart, planEnd, zone) : "";
            return "开放窗口 " + CareerFormat.Range(session.Text("start_at"), session.Text("end_at"), zone) + plan;
        }
        return string.Join(" · ", new[] { CareerFormat.Range(session.Text("start_at"), session.Text("end_at"), zone), ModeLabel(session), Interviewer(session, withRole) }.OfType<string>());
    }

    public static int QuestionCount(string markdown) => markdown.Split('\n').Count(line => CareerTranscript.QuestionText(line) is not null);

    /// <summary>对应 `applicationStageMatchesSession`，只针对投递的当前阶段。</summary>
    public static bool MatchesCurrentStage(JsonNode application, JsonNode session)
    {
        var stageId = application.Get("current_stage").Text("id");
        var sessionStage = session.Text("application_stage_id");
        if (stageId.Length > 0 && sessionStage.Length > 0) return stageId == sessionStage;
        var type = application.Text("current_stage_type");
        var label = SwiftText.TrimWhitespaces(application.Text("current_stage_label"));
        if (type == "screening" && session.Text("stage_type") == "other") return label == SwiftText.TrimWhitespaces(session.Text("stage_label"));
        if (type != session.Text("stage_type")) return false;
        if (type == "interview") return CareerJson.OptionalInteger(application, "current_round_no") == CareerJson.OptionalInteger(session, "round_no");
        return label == SwiftText.TrimWhitespaces(session.Text("stage_label"));
    }
}

/// <summary>
/// Web `applicationDetailModel.ts`（04.C01 求职进度页）的原生移植。
/// 页面只有一个「下一步」主操作，文案取决于阶段 × 阶段内状态；已安排的场次按时间完成，结束时间一过就进入等待结果。
/// </summary>
public sealed class CareerDetailModel
{
    public bool Ended { get; }
    public bool Pending { get; }
    public bool VerbalOffer { get; }
    public string HeaderMeta { get; }
    public string CurrentLabel { get; }
    public IReadOnlyList<CareerDetailStep> Steps { get; }
    public CareerDetailNext Next { get; }
    public IReadOnlyList<CareerHistoryItem> History { get; }
    public CareerOfferCard? OfferCard { get; }
    public IReadOnlyList<CareerInfoRow> DeliveryRows { get; }
    /// <summary>阶段级操作（记录、改期、取消）作用的场次。</summary>
    public JsonNode? CurrentSession { get; }
    /// <summary>最新一场已结束的场次，用于「查看复盘」和关联录音。</summary>
    public JsonNode? LatestRecorded { get; }

    static string StageKind(string type) => type switch { "written_test" => "笔试", "assessment" => "测评", "ai_interview" => "AI 面试", "hr" => "HR 面", _ => "面试" };

    static string? Salary(JsonNode app)
    {
        var amount = app.Display("offer_salary");
        if (amount.Length == 0) return null;
        return amount + (app.Text("offer_salary_period") switch { "year" => " / 年", "month" => " / 月", _ => "" });
    }

    static string? Source(JsonNode app) => CareerDeck.Source(app);

    static string? NonEmpty(string value) => SwiftText.TrimAll(value).Length == 0 ? null : SwiftText.TrimAll(value);

    /// <summary>投递状态机面向产品的投影（`projectApplicationProgress`）。</summary>
    public static string Column(JsonNode app)
    {
        var active = app.Text("lifecycle_status") != "terminated" && app.Text("status") == "active" && app.Text("archived_at").Length == 0;
        if (app.Text("archived_at").Length == 0 && app.Text("status") == "closed" && app.Text("offer_status") == "accepted") return "offer";
        if (!active) return "ended";
        var current = app.Get("current_stage").Text("stage_type");
        var hasCurrent = app.Get("current_stage").Text("id").Length > 0;
        var phase = app.Text("phase").Length == 0
            ? (app.Text("applied_at").Length > 0 || hasCurrent || app.Text("current_stage_type") != "screening" ? "applied" : "pending")
            : app.Text("phase");
        if (phase == "pending") return "pending";
        var stable = current;
        if (stable.Length == 0)
        {
            stable = app.Text("current_stage_type");
            if (stable == "hr") stable = "interview";
            if (stable == "screening")
            {
                var label = SwiftText.Lower(app.Text("current_stage_label"));
                if (SwiftText.Contains(label, "笔试")) stable = "written_test";
                else if (SwiftText.Contains(label, "测评") || SwiftText.Contains(label, "assessment")) stable = "assessment";
            }
        }
        if (stable is "offer" or "oc") return "offer";
        return stable is "screening" or "assessment" or "written_test" ? stable : "interview";
    }

    public CareerDetailModel(JsonNode app, IEnumerable<JsonNode> all, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var at = now ?? Beijing.Now;
        var tz = zone ?? Beijing.Zone;
        string Md(string raw) => CareerFormat.MonthDay(raw, tz);
        int Days(string raw) => CareerApplication.Date(raw) is { } date ? Math.Max(0, CareerFormat.Days(date, at, tz)) : 0;
        var columnKey = Column(app);
        var appId = app.Text("id");
        var sessions = CareerJson.StableSort(all.Where(x => x.Text("application_id") == appId).Select(x => CareerSessions.WithEffectiveStatus(x, at)),
            (a, b) => (CareerApplication.Date(b.Text("start_at")) ?? SwiftDates.DistantPast).CompareTo(CareerApplication.Date(a.Text("start_at")) ?? SwiftDates.DistantPast));
        var recorded = CareerJson.StableSort(app.Items("stages"), (a, b) => a.Integer("sequence_no").CompareTo(b.Integer("sequence_no")));
        var pending = columnKey == "pending";
        var stages = recorded;
        if (stages.Count == 0 && !pending)
        {
            // 阶段历史出现之前的记录只带当前阶段的平铺字段。
            var legacyEnded = columnKey == "ended";
            var type = app.Text("current_stage_type") == "offer" ? "offer" : columnKey is "assessment" or "written_test" ? columnKey : app.Text("current_stage_type") == "screening" ? "screening" : "interview";
            stages = [new JsonObject
            {
                ["id"] = "legacy-" + appId, ["stage_type"] = type,
                ["stage_label"] = SwiftText.TrimWhitespaces(app.Text("current_stage_label")).Length == 0 ? CareerStage.Label(columnKey) : app.Text("current_stage_label"),
                ["stage_status"] = legacyEnded ? "completed" : "active", ["stage_result"] = app.Text("status") == "rejected" ? "rejected" : "pending",
                ["current_marker"] = legacyEnded ? null : 1.0, ["entered_at"] = app.Text("applied_at").Length == 0 ? app.Text("updated_at") : app.Text("applied_at"),
                ["completed_at"] = legacyEnded ? app.Text("updated_at") : null,
            }];
        }
        var currentFromApp = app.Get("current_stage") is { } fromApp && fromApp.Text("id").Length > 0 ? fromApp : null;
        var current = currentFromApp ?? stages.FirstOrDefault(x => CareerJson.IsInteger(x.Get("current_marker"), 1));
        var currentId = current.Text("id");
        var currentSession = sessions.FirstOrDefault(x => x.Text("status") != "cancelled" && CareerSessions.MatchesCurrentStage(app, x));
        var ended = columnKey == "ended";
        var offer = !ended && app.Text("current_stage_type") == "offer";
        var offerStatus = app.Text("offer_status");
        var offerReceived = offer && offerStatus == "received";
        var hasOc = stages.Any(x => x.Text("stage_type") == "oc");
        var verbalOffer = offer && offerStatus == "none" && (current?.Text("stage_type") == "oc" || !hasOc);
        bool IsLegacyOc(JsonNode stage) => stage.Text("stage_type") == "offer" && offerStatus == "none" && !hasOc && stage.Text("id") == currentId;
        var rejected = app.Text("status") == "rejected" || app.Text("termination_reason") == "company_rejected";
        var accepted = offerStatus == "accepted";
        var resumeTitle = NonEmpty(app.Text("resume_title_snapshot"));
        var source = Source(app);
        var scheduledSession = currentSession?.Text("status") == "scheduled" ? currentSession : null;
        var elapsedSession = currentSession?.Text("status") == "completed" ? currentSession : null;
        var stageState = app.Text("stage_state") == "scheduled" && scheduledSession is null && elapsedSession is not null ? "awaiting_result" : app.Text("stage_state");
        JsonNode? SessionFor(JsonNode stage) => sessions.FirstOrDefault(x => x.Text("status") != "cancelled" && (x.Text("application_stage_id").Length > 0
            ? x.Text("application_stage_id") == stage.Text("id")
            : SwiftText.TrimWhitespaces(x.Text("stage_label")) == SwiftText.TrimWhitespaces(stage.Text("stage_label"))));
        string StageLabel(JsonNode stage)
        {
            var type = stage.Text("stage_type");
            if (type == "oc" || IsLegacyOc(stage)) return stage.Text("id") == currentId ? "OC · 口头意向" : "OC";
            if (type == "offer") return "Offer";
            if (type == "screening") return "筛选中";
            return stage.Text("stage_label");
        }
        var lastId = stages.Count > 0 ? stages[^1].Text("id") : null;

        // 进度条
        var steps = new List<CareerDetailStep>();
        if (pending)
        {
            steps.Add(new("pending", "待投递", Md(app.Text("created_at")) + " 导入", CareerDetailStepState.Current));
            foreach (var (key, label, meta) in new[] { ("screening", "筛选中", ""), ("test", "笔试 / 测评", ""), ("interview", "面试", "可多轮"), ("offer", "Offer", "") })
                steps.Add(new(key, label, meta, CareerDetailStepState.Todo));
        }
        else
        {
            steps.Add(new("applied", "已投递", Md(app.Text("applied_at").Length == 0 ? app.Text("created_at") : app.Text("applied_at")), CareerDetailStepState.Done));
            foreach (var stage in stages)
            {
                string id = stage.Text("id"), type = stage.Text("stage_type");
                var isCurrent = !ended && id == currentId;
                var session = SessionFor(stage);
                if (type == "oc")
                {
                    steps.Add(new(id, StageLabel(stage), Md(app.Text("oc_communicated_at").Length == 0 ? stage.Text("entered_at") : app.Text("oc_communicated_at")), isCurrent ? CareerDetailStepState.Current : CareerDetailStepState.Done));
                    continue;
                }
                if (type == "offer")
                {
                    var received = offerStatus != "none";
                    var receivedDay = CareerFormat.OfferDay(app.Text("offer_received_on"), tz) ?? Md(stage.Text("entered_at"));
                    steps.Add(new(id, StageLabel(stage), received ? receivedDay + " · 已收到" : Md(stage.Text("entered_at")), received ? CareerDetailStepState.Offer : isCurrent ? CareerDetailStepState.Current : CareerDetailStepState.Done));
                    continue;
                }
                var completedOrEntered = stage.Text("completed_at").Length == 0 ? stage.Text("entered_at") : stage.Text("completed_at");
                if (stage.Text("stage_result") == "rejected" || ended && id == lastId && rejected)
                {
                    steps.Add(new(id, StageLabel(stage), Md(completedOrEntered) + " · 未通过", CareerDetailStepState.Failed));
                    continue;
                }
                if (isCurrent)
                {
                    string meta;
                    if (stageState == "awaiting_result" && session is not null && session.Text("status") == "completed")
                        meta = Md(session.Text("start_at")) + (type is "interview" or "hr" ? " · 已面完" : " · 已考完");
                    else if (session is not null && session.Text("schedule_kind") == "open_window")
                        meta = Md(session.Text("start_at")) + "–" + Md(session.Text("end_at"));
                    else if (session is not null) meta = Md(session.Text("start_at"));
                    else meta = Md(stage.Text("entered_at")) + " 起";
                    steps.Add(new(id, StageLabel(stage), meta, CareerDetailStepState.Current));
                    continue;
                }
                var passed = stage.Text("stage_result") == "passed" && stages.Count < 5;
                var when = stage.Text("completed_at").Length > 0 ? stage.Text("completed_at") : session?.Text("start_at") ?? stage.Text("entered_at");
                steps.Add(new(id, type == "screening" ? "筛选" : StageLabel(stage), passed ? Md(when) + " · 已通过" : Md(when), CareerDetailStepState.Done));
            }
            if (!ended && !offer)
                steps.Add(new("next", "下一阶段", current?.Text("stage_type") == "screening" ? "由结果决定" : "", CareerDetailStepState.Next));
        }

        // 下一步
        var stageName = current is not null ? current.Text("stage_label") : CareerStage.Label(columnKey);
        var kind = current is not null ? StageKind(current.Text("stage_type")) : "面试";
        CareerDetailNext next;
        CareerDetailButton Button(CareerDetailAction action, string label, bool danger = false, bool dark = true) => new(action, label, danger, dark);
        if (pending)
        {
            next = new("下一步", new CareerDetailTile.Status("待投递", $"{Days(app.Text("created_at"))} 天", CareerTone.Gray), [new("待投递", CareerTone.Gray)],
                "投递后，记录这次求职从哪一步开始", "可直接进入筛选中，也可以跳到笔试、面试或 Offer", null, Button(CareerDetailAction.RecordApplied, "记录投递"), []);
        }
        else if (ended)
        {
            var lastLabel = stages.Count > 0 ? StageLabel(stages[^1]) : CareerStage.Label(columnKey);
            var reviewed = sessions.Count(x => SwiftText.TrimAll(x.Text("review_summary")).Length > 0);
            var (sub, tone, title, chip) = rejected
                ? ("未通过", CareerTone.Red, $"流程已结束：{lastLabel}未通过", $"结束阶段：{lastLabel}")
                : accepted ? ("已接受", CareerTone.Green, "流程已结束：已接受 Offer", "已接受 Offer")
                : offerStatus == "declined" ? ("已婉拒", CareerTone.Gray, "流程已结束：已婉拒 Offer", "已婉拒 Offer")
                : ("已放弃", CareerTone.Gray, "流程已结束：主动放弃", $"结束阶段：{lastLabel}");
            var detail = string.Join(" · ", new[] { app.Text("terminated_at").Length == 0 ? null : Md(app.Text("terminated_at")) + " " + (rejected ? "收到拒信" : "结束"),
                $"共经历 {stages.Count} 个阶段", reviewed > 0 ? $"{reviewed} 场面试有复盘" : null }.OfType<string>());
            next = new("当前", new CareerDetailTile.Status("已结束", sub, tone), [new("已结束", CareerTone.Gray), new(chip, tone)],
                title, detail, null, Button(CareerDetailAction.ViewReview, "查看复盘", dark: false), []);
        }
        else if (offerReceived)
        {
            var deadlineChip = new CareerChip("待你决定", CareerTone.Orange);
            if (CareerFormat.OfferDate(app.Text("offer_reply_due_on"), tz) is { } due)
            {
                var left = CareerFormat.Days(at, due, tz);
                deadlineChip = new(left == 0 ? "今天截止" : left > 0 ? $"还有 {left} 天回复" : $"回复截止已过 {-left} 天", left < 0 ? CareerTone.Red : CareerTone.Orange);
            }
            var dueDay = CareerFormat.OfferDay(app.Text("offer_reply_due_on"), tz);
            var detail = string.Join(" · ", new[] { NonEmpty(app.Text("offer_base_location")), Salary(app), NonEmpty(app.Text("offer_benefits_description")), dueDay is null ? null : "回复截止 " + dueDay }.OfType<string>());
            next = new("下一步", new CareerDetailTile.Status("Offer", "已收到", CareerTone.Green), [new("Offer", CareerTone.Dark), new("已收到", CareerTone.Green), deadlineChip],
                "已收到正式 Offer，待你决定", detail.Length == 0 ? "Offer 详情待补充" : detail, null,
                Button(CareerDetailAction.AcceptOffer, "接受 Offer"), [Button(CareerDetailAction.EditOffer, "修改 Offer 信息"), Button(CareerDetailAction.DeclineOffer, "婉拒", danger: true)]);
        }
        else if (offer && !verbalOffer)
        {
            next = new("下一步", new CareerDetailTile.Status("Offer", "待补充", CareerTone.Green), [new("Offer", CareerTone.Dark), new("信息待补充", CareerTone.Orange)],
                "补充正式 Offer 信息", "记录收到日期、回复截止和薪酬，方便按时回复", null, Button(CareerDetailAction.EditOffer, "记录正式 Offer"), []);
        }
        else if (offer)
        {
            var ocSalary = NonEmpty(app.Text("oc_salary_text"));
            var ocStart = NonEmpty(app.Text("oc_start_text"));
            var detail = string.Join(" · ", new[] {
                current is null ? null : Md(app.Text("oc_communicated_at").Length == 0 ? current.Text("entered_at") : app.Text("oc_communicated_at")) + " 收到口头意向",
                ocSalary is null ? null : "口头薪酬 " + ocSalary, ocStart is null ? null : "预计到岗 " + ocStart,
                current?.Text("stage_type") == "oc" ? null : NonEmpty(app.Text("notes")) }.OfType<string>());
            next = new("下一步", new CareerDetailTile.Status("OC", "口头意向", CareerTone.Blue), [new("Offer 阶段", CareerTone.Dark), new("口头意向", CareerTone.Blue), new("正式 Offer 未到", CareerTone.Orange)],
                "已收到口头意向，等待正式 Offer", detail, null, Button(CareerDetailAction.RecordOffer, "记录正式 Offer"), []);
        }
        else if (current?.Text("stage_type") == "screening" || current is null && app.Text("current_stage_type") == "screening")
        {
            var start = current is not null ? current.Text("entered_at") : app.Text("applied_at").Length == 0 ? app.Text("created_at") : app.Text("applied_at");
            var detail = string.Join(" · ", new[] { source is not null ? $"{Md(app.Text("applied_at"))} 通过{source}投递" : $"{Md(app.Text("applied_at"))} 投递", resumeTitle }.OfType<string>());
            next = new("下一步", new CareerDetailTile.Status("筛选中", $"第 {Days(start) + 1} 天", CareerTone.Blue), [new("筛选中", CareerTone.Blue), new("等待结果", CareerTone.Orange)],
                "等待简历筛选结果", detail, null, Button(CareerDetailAction.Advance, "进入下一阶段"), []);
        }
        else if (stageState == "awaiting_schedule")
        {
            next = new("下一步", new CareerDetailTile.Status("待安排", "", CareerTone.Orange), [new(stageName, CareerTone.Blue), new("等待安排", CareerTone.Orange)],
                $"安排{stageName}时间", $"已收到{stageName}通知，还没填时间", null, Button(CareerDetailAction.Schedule, $"安排{stageName}时间"), []);
        }
        else if (scheduledSession is { } session)
        {
            var openWindow = session.Text("schedule_kind") == "open_window";
            var anchorRaw = openWindow ? session.Text("end_at") : session.Text("start_at");
            var anchor = CareerApplication.Date(anchorRaw) ?? at;
            var local = SwiftCalendar.Local(anchor, tz);
            var weekday = "日一二三四五六"[(SwiftCalendar.Weekday(anchor, tz) - 1) % 7];
            var left = CareerFormat.Days(at, anchor, tz);
            var chips = new List<CareerChip> { new(stageName, CareerTone.Blue), new("已安排", CareerTone.Blue), openWindow ? new("截止前完成", CareerTone.Gray) : left >= 1 ? new($"还有 {left} 天", CareerTone.Orange) : new("今天", CareerTone.Orange) };
            var total = session.Integer("prep_total");
            if (total > 0) chips.Add(new($"准备清单 {session.Integer("prep_done")}/{total}", CareerTone.Gray));
            var end = session.Text("end_at");
            next = new("下一步", new CareerDetailTile.Date(openWindow ? $"{local.Month}月 · 截止" : $"{local.Month}月 · 周{weekday}", $"{local.Day}", CareerFormat.Clock(anchorRaw, tz)),
                chips, openWindow ? $"{Md(end)} {CareerFormat.Clock(end, tz)} 前完成{stageName}" : stageName,
                CareerSessions.Line(session, withRole: true, tz),
                openWindow ? "截止时间过后自动进入「等待结果」，无需手动标记完成" : $"{kind}结束（{CareerFormat.Clock(end, tz)}）后自动进入「等待结果」，无需手动标记完成",
                openWindow ? Button(CareerDetailAction.AnswerPlan, "作答计划") : Button(CareerDetailAction.RecordReview, "记录与复盘"),
                [Button(CareerDetailAction.Reschedule, "修改安排"), Button(CareerDetailAction.CancelSession, "取消本场")]);
        }
        else
        {
            var waited = elapsedSession is not null ? Days(elapsedSession.Text("end_at")) : 0;
            var asked = elapsedSession is not null ? CareerSessions.QuestionCount(elapsedSession.Text("questions_markdown")) : 0;
            var detail = elapsedSession is not null
                ? string.Join(" · ", new[] { CareerFormat.Range(elapsedSession.Text("start_at"), elapsedSession.Text("end_at"), tz), CareerSessions.ModeLabel(elapsedSession), asked > 0 ? $"已记录 {asked} 个问题" : null }.OfType<string>())
                : "有新进展时在这里添加下一阶段";
            next = new("下一步", new CareerDetailTile.Status("等结果", waited > 0 ? $"已 {waited} 天" : "今天结束", CareerTone.Orange), [new(stageName, CareerTone.Blue), new("等待结果", CareerTone.Orange)],
                $"{stageName}已结束，等待{kind}结果", detail, null, Button(CareerDetailAction.Advance, "通过，添加下一轮"), []);
        }

        // 阶段记录（新的在前）
        var history = Enumerable.Reverse(stages).Select(stage =>
        {
            string id = stage.Text("id"), type = stage.Text("stage_type");
            var session = SessionFor(stage);
            var isCurrent = !ended && id == currentId;
            var isFailed = stage.Text("stage_result") == "rejected" || ended && rejected && id == lastId;
            var chip = new CareerChip("已通过", CareerTone.Green);
            CareerTone? dot = CareerTone.Green;
            if (isFailed) { chip = new("未通过", CareerTone.Red); dot = CareerTone.Red; }
            else if (type == "oc") { chip = isCurrent ? new("待正式 Offer", CareerTone.Blue) : new("已转正式", CareerTone.Green); dot = isCurrent ? CareerTone.Blue : CareerTone.Green; }
            else if (type == "offer")
            {
                chip = offerStatus == "none" ? new("待正式 Offer", CareerTone.Blue) : offerStatus == "accepted" ? new("已接受", CareerTone.Green) : offerStatus == "declined" ? new("已婉拒", CareerTone.Gray) : new("已收到", CareerTone.Green);
                dot = isCurrent && offerStatus == "none" ? CareerTone.Blue : CareerTone.Green;
            }
            else if (isCurrent)
            {
                chip = type == "screening" || stageState == "awaiting_result" ? new("等待结果", type == "screening" ? CareerTone.Blue : CareerTone.Orange)
                    : stageState == "awaiting_schedule" ? new("等待安排", CareerTone.Orange) : new("已安排", CareerTone.Blue);
                dot = chip.Tone == CareerTone.Orange ? CareerTone.Orange : CareerTone.Blue;
            }
            else if (stage.Text("stage_result") == "skipped") { chip = new("已跳过", CareerTone.Gray); dot = null; }
            string detail;
            if (session is not null)
            {
                var status = session.Text("status");
                if (session.Text("schedule_kind") == "open_window" && status == "completed") detail = "截止前完成 · " + CareerFormat.Range(session.Text("start_at"), session.Text("end_at"), tz);
                else if (status == "completed" && type is not ("interview" or "hr")) detail = CareerFormat.Range(session.Text("start_at"), session.Text("end_at"), tz) + " 完成";
                else if (status == "completed") detail = CareerSessions.Line(session, zone: tz) + " · " + CareerReview.StatusText(session);
                else detail = CareerSessions.Line(session, zone: tz);
            }
            else if (type == "oc")
            {
                var ocSalary = NonEmpty(app.Text("oc_salary_text"));
                detail = string.Join(" · ", new[] { ocSalary is null ? null : "口头薪酬 " + ocSalary, NonEmpty(app.Text("oc_contact")) }.OfType<string>()).Or("已收到口头意向");
            }
            else if (type == "screening") detail = isCurrent ? "招聘方暂未回复。筛选阶段不需要安排时间。" : "已通过简历筛选";
            else if (type == "offer")
            {
                detail = offerStatus == "none"
                    ? (hasOc ? "正式 Offer 信息待补充" : NonEmpty(app.Text("notes")) ?? "已收到口头意向，等待正式 Offer")
                    : string.Join(" · ", new[] { NonEmpty(app.Text("offer_base_location")), Salary(app) }.OfType<string>()).Or("已收到正式 Offer");
            }
            else if (isCurrent && stageState == "awaiting_schedule") detail = $"{StageKind(type)}链接与时间待招聘方确认。";
            else detail = "暂无安排记录";
            var when = type == "oc" && app.Text("oc_communicated_at").Length > 0 ? app.Text("oc_communicated_at")
                : isCurrent ? session?.Text("start_at") ?? stage.Text("entered_at")
                : stage.Text("completed_at").Length > 0 ? stage.Text("completed_at") : session?.Text("start_at") ?? stage.Text("entered_at");
            var title = type == "screening" ? "简历筛选" : type == "oc" || IsLegacyOc(stage) ? "OC · 口头意向" : type == "offer" ? "正式 Offer" : stage.Text("stage_label");
            return new CareerHistoryItem(id, Md(when), title, chip, detail, dot, isCurrent ? CareerTone.Blue : isFailed ? CareerTone.Red : null, session?.Text("id"));
        }).ToList();
        if (app.Text("applied_at").Length > 0)
            history.Add(new("applied", Md(app.Text("applied_at")), "提交投递", new("已投递", CareerTone.Gray),
                string.Join(" · ", new[] { source, resumeTitle }.OfType<string>()).Or("已记录投递"), null, null, null));

        // 侧栏卡片
        CareerOfferCard? offerCard = null;
        if (offerReceived || ended && offerStatus != "none")
        {
            var rows = new List<CareerInfoRow> { new("工作地点", NonEmpty(app.Text("offer_base_location")) ?? "—"), new("薪资", Salary(app) ?? "—"), new("福利", NonEmpty(app.Text("offer_benefits_description")) ?? "—") };
            foreach (var (title, value) in new[] { ("收到日期", CareerFormat.OfferLong(app.Text("offer_received_on"), tz)), ("回复截止", CareerFormat.OfferLong(app.Text("offer_reply_due_on"), tz)),
                         ("预计入职", CareerFormat.OfferLong(app.Text("offer_start_on"), tz)), ("试用期", NonEmpty(app.Text("offer_probation"))) })
                if (value is not null) rows.Add(new(title, value));
            rows.Add(new("状态", offerStatus == "accepted" ? "已接受" : offerStatus == "declined" ? "已婉拒" : "已收到 · 待决定", offerStatus == "declined" ? CareerTone.Gray : CareerTone.Green));
            offerCard = new("Offer 信息", "编辑", rows);
        }
        else if (verbalOffer)
        {
            var rows = new List<CareerInfoRow> { new("沟通时间", current is not null ? Md(app.Text("oc_communicated_at").Length == 0 ? current.Text("entered_at") : app.Text("oc_communicated_at")) : "—") };
            if (NonEmpty(app.Text("oc_contact")) is { } contact) rows.Add(new("沟通方式", contact));
            if (NonEmpty(app.Text("oc_salary_text")) is { } salary) rows.Add(new("口头薪酬", salary));
            if (NonEmpty(app.Text("oc_start_text")) is { } startText) rows.Add(new("预计到岗", startText));
            rows.Add(new("Offer 状态", "未收到书面", CareerTone.Orange));
            offerCard = new("口头意向", "记录 Offer", rows);
        }
        var deliveryRows = new List<CareerInfoRow> { new("投递日期", app.Text("applied_at").Length == 0 ? "未投递" : Md(app.Text("applied_at"))), new("投递渠道", source ?? "—"), new("投递简历", resumeTitle ?? "未关联") };

        Ended = ended;
        Pending = pending;
        VerbalOffer = verbalOffer;
        HeaderMeta = ended ? "已结束" : pending ? $"导入 {Days(app.Text("created_at"))} 天" : $"已投递 {Days(app.Text("applied_at").Length == 0 ? app.Text("created_at") : app.Text("applied_at"))} 天";
        CurrentLabel = current is not null ? current.Text("stage_label").Or(CareerStage.Label(columnKey)) : CareerStage.Label(columnKey);
        Steps = steps;
        Next = next;
        History = history;
        OfferCard = offerCard;
        DeliveryRows = deliveryRows;
        CurrentSession = currentSession;
        LatestRecorded = sessions.FirstOrDefault(x => x.Text("status") == "completed");
    }
}
