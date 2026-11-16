using System.Globalization;
using System.Text.Json.Nodes;
namespace DrawOffer.Core.Models;
public static class CareerRequest {
    /// <summary>桌面请求总白名单，与 Mac `CareerRequest.allowed` 一致：先查各模块白名单，再查求职进度与排期规则。</summary>
    public static bool Allowed(string path, string method) {
        if(DatasetRequest.Allowed(path,method))return true;
        if(MockInterviewRequest.Allowed(path,method))return true;
        if(ResumeRequest.Allowed(path,method))return true;
        if(AccountRequest.Allowed(path,method))return true;
        if(ParityRequest.Allowed(path,method))return true;
        if(AgentRequest.Allowed(path,method)&&!AgentRequest.Streams(path,method))return true;
        if(!path.StartsWith("/api/") || path.Contains("//") || path.EndsWith("/") || path.Contains('?') || path.Contains('#') || path.Contains("..")) return false;
        if(method == "GET" && new[] { "/api/resumes", "/api/job-applications", "/api/interview-overview", "/api/interview-sessions", "/api/job-descriptions" }.Contains(path)) return true;
        if(method == "POST" && new[] { "/api/job-descriptions", "/api/job-descriptions/parse-draft", "/api/job-applications" }.Contains(path)) return true;
        if(path=="/api/plugin-releases/current")return method=="GET";
        if(path=="/api/job-matches/recommendations")return method=="GET";
        if(path=="/api/job-matches/recommendations:ensure")return method=="POST";
        var p = path.TrimStart('/').Split('/');
        if(p.Length < 3 || p[0] != "api" || p[2].Length == 0 || !p[2].All(char.IsAsciiDigit)) return false;
        if(p.Length == 3) return new[] { "job-applications", "job-descriptions" }.Contains(p[1]) ? new[] { "GET", "PUT", "DELETE" }.Contains(method) : p[1] == "interview-sessions" && method is "GET" or "PUT" or "DELETE";
        if(p.Length == 4 && p[1] == "job-descriptions" && p[3] == "logo")return method=="GET";
        if(p.Length == 4 && p[1] == "job-descriptions" && p[3] == "match")return method=="GET";
        if(p.Length == 4 && p[1] == "job-descriptions" && p[3] == "match:analyze")return method=="POST";
        if(p.Length == 4 && p[1] == "interview-sessions" && p[3] == "answer-plan") return method == "PUT";
        if(p[1] == "interview-sessions" && StageDetail(p, method) is { } stage) return stage;
        if(p.Length == 4 && p[1] == "interview-assets" && p[3] == "content") return method == "GET";
        if(p.Length != 4 || method != "POST") return false;
        return p[1] == "job-applications" ? new[] { "stages", "terminate", "offer", "close", "archive", "restore", "reopen", "interview-sessions" }.Contains(p[3]) : p[1] == "interview-sessions" && new[] { "complete", "cancel", "reschedule" }.Contains(p[3]);
    }

    /// <summary>阶段详情：录音、转写、复盘笔记、笔试导入与 AI 复盘；null 交给通用规则（Mac `stageDetail`）。</summary>
    static bool? StageDetail(string[] p, string method) {
        static bool Numeric(string value) => value.Length > 0 && value.All(c => c is >= '0' and <= '9');
        if(p.Length == 4) return p[3] switch {
            "assets" => method is "GET" or "POST",
            // 笔试题：确认导入（整体替换，带识别出的作答与判分）
            "written-questions" => method == "PUT",
            "review-notes" => method == "PUT",
            "written-questions:extract" or "review:generate" or "prep-items:generate" or "record:structure" or "record-topics" => method == "POST",
            _ => null,
        };
        if(p.Length == 5 && p[3] == "review-notes") return Numeric(p[4]) && method == "DELETE";
        // 笔试题逐题标对错
        if(p.Length == 5 && p[3] == "written-questions") return Numeric(p[4]) && method == "PATCH";
        if(p.Length == 5 && p[3] == "transcriptions") {
            var segment = p[4].Split(':');
            return segment.Length == 2 && Numeric(segment[0]) && segment[1] is "retry" or "apply" && method == "POST";
        }
        return null;
    }

    /// <summary>`career` 请求允许携带的查询参数（Mac `DesktopTransport.career`）。</summary>
    public static readonly HashSet<string> QueryKeys = ["scope", "cursor", "limit", "week_start", "timezone", "application_id", "include_archived", "v", "job_application_id", "resume_id", "status", "folder_id", "confirm_contents", "start_at", "end_at", "type", "q", "prefix", "session_id", "include_history", "keyword", "company_ids", "city", "job_category", "recruitment_type", "job_id"];
}

/// <summary>一条求职记录（`job-applications` 的一项）；`CompletedSchedule` 是当前阶段最近一场已完成场次的开始时间。</summary>
public sealed record CareerApplication(JsonNode Raw, DateTimeOffset? CompletedSchedule = null)
{
    /// <summary>结合场次补上 `CompletedSchedule`：只看当前阶段、非取消的最新一场。</summary>
    public CareerApplication IncludingSessions(IEnumerable<JsonNode> sessions)
    {
        var stageId = Raw.Get("current_stage").Text("id");
        if (stageId.Length == 0) return this;
        JsonNode? latest = null;
        foreach (var session in sessions)
        {
            if (session.Text("application_id") != Id || session.Text("application_stage_id") != stageId || session.Text("status") == "cancelled") continue;
            // Swift `max(by:)`：只在严格更大时替换，等值时保留先出现的一项。
            if (latest is null || (Date(latest.Text("start_at")) ?? SwiftDates.DistantPast) < (Date(session.Text("start_at")) ?? SwiftDates.DistantPast)) latest = session;
        }
        return new CareerApplication(Raw, latest?.Text("status") == "completed" ? Date(latest.Text("start_at")) : null);
    }

    /// <summary>`raw.text(key)` 的简写。</summary>
    public string Text(string key) => Raw.Text(key);
    public string Id => Raw.Text("id");
    public string Company => Raw.Text("company_name_snapshot");
    public string Title => Raw.Text("job_title_snapshot");
    public int LockVersion => Raw.Integer("lock_version");
    public bool Ended => Raw.Text("lifecycle_status") == "terminated" || Raw.Text("status") is not ("" or "active") || Raw.Text("archived_at").Length > 0;

    /// <summary>公司 Logo：只接受本站相对路径 `/api/job-descriptions/{id}/logo?v={64 位小写十六进制}`（按 `URLComponents` 规则解析）。</summary>
    public (string Path, string Revision)? LogoRequest
    {
        get
        {
            if (RelativeUrl.Parse(Raw.Text("company_logo_url")) is not { } url) return null;
            if (!CareerRequest.Allowed(url.Path, "GET") || !url.Path.EndsWith("/logo", StringComparison.Ordinal)) return null;
            if (url.Query is not [var query] || query.Name != "v" || query.Value is not { } revision) return null;
            var characters = SwiftText.Elements(revision);
            if (characters.Length != 64 || !characters.All(c => SwiftText.InRange(c, "0", "9") || SwiftText.InRange(c, "a", "f"))) return null;
            return (url.Path, revision);
        }
    }

    public string Category => Raw.Get("job_snapshot").Text("employment_type");
    public string CategoryLabel => Category switch { "internship" => "实习", "campus" => "校招", "full_time" => "正式", _ => "未分类" };

    public string Stage
    {
        get
        {
            if (Ended) return "ended";
            if (Raw.Text("phase") == "pending" || Raw.Text("phase").Length == 0 && Raw.Text("applied_at").Length == 0 && Raw.Get("current_stage") is null && Raw.Text("current_stage_type") == "screening") return "pending";
            var value = Raw.Get("current_stage").Text("stage_type").Or(Raw.Text("current_stage_type"));
            if (value == "hr") return "interview";
            if (value == "oc") return "offer";
            if (value == "screening")
            {
                if (SwiftText.Contains(Raw.Text("current_stage_label"), "笔试")) return "written_test";
                if (SwiftText.Contains(Raw.Text("current_stage_label"), "测评")) return "assessment";
            }
            return CareerStage.Keys.Contains(value) ? value : "screening";
        }
    }

    public string StageLabel
    {
        get
        {
            if (Stage == "offer" && Raw.Text("offer_status") == "none") return "OC";
            return Stage is "interview" or "ai_interview"
                ? Raw.Get("current_stage").Text("stage_label").Or(Raw.Text("current_stage_label")).Or(CareerStage.Label(Stage))
                : CareerStage.Label(Stage);
        }
    }

    /// <summary>看板列。已接受的 Offer 与 Web 一样留在 Offer 列，虽然流程已结束。</summary>
    public string Column
    {
        get
        {
            if (Raw.Text("archived_at").Length == 0 && Raw.Text("status") == "closed" && Raw.Text("offer_status") == "accepted") return "offer";
            return Stage is "interview" or "ai_interview" ? "interview:" + StageLabel : Stage;
        }
    }

    public string StatusLabel
    {
        get
        {
            if (Raw.Text("offer_status") == "accepted") return "已接受 Offer";
            if (Raw.Text("offer_status") == "declined") return "已婉拒 Offer";
            if (Stage == "pending") return "等待确认投递";
            if (Ended) return "结束阶段：" + Raw.Text("current_stage_label").Or(CareerStage.Label(Raw.Text("current_stage_type")));
            if (Raw.Text("stage_state") == "completed" || CompletedSchedule is not null) return "已完成";
            if (Stage == "offer") return Raw.Text("offer_status") == "none" ? "OC 口头意向" : "已收到 Offer";
            if (Raw.Text("stage_state") == "awaiting_schedule") return "等待安排";
            if (Raw.Text("stage_state") == "awaiting_result") return "等待结果";
            if (Raw.Text("stage_state") == "scheduled") return "已安排";
            return StageLabel;
        }
    }

    public bool Movable => !Ended && Stage != "offer";

    /// <summary>需要排期的阶段的下一场开始时间（Mac `scheduleDate`）。</summary>
    public DateTimeOffset? ScheduleDate => Stage is "assessment" or "written_test" or "ai_interview" or "interview" ? Date(Raw.Text("next_session_start_at")) : null;

    /// <summary>ISO 8601（带或不带小数秒）；不带时区的时间（如 `2026-10-31T06:28:41.227684`）按本地时间读，与浏览器 `new Date()` 一致。</summary>
    public static DateTimeOffset? Date(string text) => SwiftDate.Parse(text);
}

public static class CareerStage
{
    public static readonly string[] Keys = ["pending", "screening", "assessment", "written_test", "ai_interview", "interview", "offer", "ended"];

    public static string[] NextStages(CareerApplication? item)
    {
        var candidates = Keys.Where(k => k is not ("pending" or "ended")).ToArray();
        if (item is null) return candidates;
        var rank = Math.Max(0, Array.IndexOf(Keys, item.Stage));
        return candidates.Where(k => k == "interview" ? rank <= Index(k, 0) : rank < Index(k, 0)).ToArray();
    }

    static int Index(string key, int fallback) => Array.IndexOf(Keys, key) is var index and >= 0 ? index : fallback;

    public static bool CanAdvance(CareerApplication item, string column, string? stage = null)
    {
        var target = stage ?? (column.StartsWith("interview:", StringComparison.Ordinal) ? "interview" : column);
        if (!item.Movable || item.Column == column || target == "pending") return false;
        return target == "ended" || Index(target, -1) >= Index(item.Stage, int.MaxValue);
    }

    public static string Label(string key) => key switch
    {
        "pending" => "待投递", "screening" => "筛选中", "assessment" => "测评", "written_test" => "笔试",
        "ai_interview" => "AI 面试", "interview" => "面试中", "offer" => "Offer", "ended" => "已结束", _ => key,
    };

    public static string[] Columns(IEnumerable<CareerApplication> applications)
    {
        var rounds = applications.Where(x => x.Stage is "interview" or "ai_interview").GroupBy(x => x.Column)
            .ToDictionary(g => g.Key, g => g.Select(x => x.Raw.Integer("current_round_no")).Where(n => n > 0).DefaultIfEmpty(int.MaxValue).Min());
        var ordered = rounds.Keys.OrderBy(k => rounds[k]).ThenBy(k => k, SwiftText.Ordering).ToArray();
        return Keys.Where(k => k != "ai_interview").SelectMany(k => k == "interview" ? (ordered.Length == 0 ? ["interview:面试中"] : ordered) : new[] { k }).ToArray();
    }

    public static IEnumerable<CareerApplication> Sorted(IEnumerable<CareerApplication> applications, bool earliest) =>
        applications.OrderBy(x => x, Comparer<CareerApplication>.Create((left, right) =>
        {
            if (!earliest)
            {
                if (left.ScheduleDate is { } l && right.ScheduleDate is { } r && l != r) return l < r ? -1 : 1;
                if (left.ScheduleDate is not null && right.ScheduleDate is null) return -1;
                if (left.ScheduleDate is null && right.ScheduleDate is not null) return 1;
                if (left.CompletedSchedule is { } lc && right.CompletedSchedule is { } rc && lc != rc) return lc > rc ? -1 : 1;
                if (left.CompletedSchedule is not null && right.CompletedSchedule is null) return -1;
                if (left.CompletedSchedule is null && right.CompletedSchedule is not null) return 1;
            }
            var created = (CareerApplication.Date(left.Raw.Text("created_at")) ?? SwiftDates.DistantFuture).CompareTo(CareerApplication.Date(right.Raw.Text("created_at")) ?? SwiftDates.DistantFuture);
            return created != 0 ? created : SwiftText.StandardCompare(left.Id, right.Id);
        }));
}

/// <summary>V4 唯一的页面级主操作；阶段历史从不改变流程。</summary>
public sealed record CareerFlow
{
    public string Kind { get; }
    public string Button { get; }
    public string Headline { get; }
    public string Explanation { get; }

    public CareerFlow(CareerApplication item)
    {
        if (item.Ended)
        {
            Kind = "history"; Button = "查看阶段记录";
            Headline = item.Raw.Text("offer_status") == "accepted" ? "已接受 Offer" : item.Raw.Text("offer_status") == "declined" ? "已婉拒 Offer" : "本次求职已结束";
            Explanation = "保留每个阶段的记录，回顾这次求职经历。";
        }
        else if (item.Stage == "pending")
        {
            Kind = "apply"; Button = "记录投递"; Headline = "准备好了，就记录一次投递。";
            Explanation = "记录投递日期、渠道和使用的简历，开始跟进这个岗位。";
        }
        else if (item.Stage == "offer")
        {
            var received = item.Raw.Text("offer_status") == "received";
            Kind = received ? "accept" : "offer"; Button = received ? "接受 Offer" : "记录正式 Offer";
            Headline = received ? "正式 Offer 已收到，做出你的选择。" : "口头意向已沟通，等待正式 Offer。";
            Explanation = received ? "核对薪酬、工作地点和入职信息，再确认是否接受。" : "收到正式 Offer 后，记录条件并决定接受或婉拒。";
        }
        else if (item.Stage is "assessment" or "written_test" or "ai_interview" or "interview" && item.Raw.Text("stage_state") == "awaiting_schedule")
        {
            Kind = "schedule-current"; Button = "安排时间"; Headline = "先把时间安排好。";
            Explanation = "记录时间、方式和链接，排期会同步到面试日程。";
        }
        else if (item.Raw.Text("stage_state") == "scheduled" && item.CompletedSchedule is null)
        {
            Kind = "records"; Button = "记录与复盘"; Headline = "已安排，准备好迎接这次机会。";
            Explanation = "查看排期、记录面试情况；结束后标记完成。";
        }
        else
        {
            Kind = "stage"; Button = item.Stage == "screening" ? "进入下一阶段" : "通过，添加下一轮";
            Headline = "等待结果，有进展再记录。";
            Explanation = "收到通过通知后，添加下一阶段；多轮面试会分别保留记录。";
        }
    }

    /// <summary>旧调用方式，等同 <c>new CareerFlow(item)</c>。</summary>
    public static CareerFlow For(CareerApplication item) => new(item);
}

/// <summary>共享 schema 存在备注里的 V4 字段；不相关的行全部保留。</summary>
public static class CareerNotes
{
    public static readonly string[] Fields = ["投递渠道", "口头薪酬", "收到日期", "回复截止", "薪酬说明", "预计入职", "试用期", "Offer 材料"];

    public static string Value(string field, string notes) =>
        notes.Split('\n').FirstOrDefault(line => SwiftText.HasPrefix(line, field + "：")) is { } line ? line[(field.Length + 1)..] : "";

    /// <summary>去掉 V4 字段行后剩下的自由文本。</summary>
    public static string FreeText(string notes) =>
        string.Join('\n', notes.Split('\n').Where(line => !Fields.Any(field => SwiftText.HasPrefix(line, field + "："))));

    /// <summary>Mac `merging(_:into:)`：只替换给出的字段，空值即删除该行。</summary>
    public static string Merge(Dictionary<string, string> values, string notes)
    {
        var keys = values.Keys.Where(Fields.Contains).ToHashSet();
        var lines = notes.Split('\n').Where(line => !keys.Any(key => SwiftText.HasPrefix(line, key + "："))).ToList();
        foreach (var key in Fields.Where(keys.Contains))
            if (values[key].Length > 0) lines.Add(key + "：" + values[key].Replace("\n", " "));
        return SwiftText.TrimNewlines(string.Join('\n', lines));
    }
}

public sealed record CareerProgressStep(string Id, string Label, string Date, string State);

public static class CareerProgress
{
    public static CareerProgressStep[] Steps(CareerApplication item)
    {
        var stages = item.Raw.Items("stages");
        if (stages.Count == 0)
        {
            var type = item.Ended ? item.Raw.Text("current_stage_type") : item.Stage;
            var rank = type == "pending" ? 0 : type == "screening" ? 1 : type is "assessment" or "written_test" ? 2 : type == "offer" ? 4 : 3;
            return new[] { "待投递", "筛选中", "笔试 / 测评", "面试", "Offer" }
                .Select((label, index) => new CareerProgressStep(index.ToString(CultureInfo.InvariantCulture), label, index == 0 ? item.Raw.Text("created_at") : "", index == rank && !item.Ended ? "current" : "future")).ToArray();
        }
        var currentId = item.Raw.Get("current_stage").Text("id");
        var result = new List<CareerProgressStep> { new("applied", "已投递", item.Raw.Text("applied_at"), "completed") };
        var last = stages[^1];
        foreach (var stage in stages)
        {
            var isCurrent = stage.Text("id") == currentId || currentId.Length == 0 && JsonNode.DeepEquals(stage, last);
            var state = !item.Ended && isCurrent ? "current" : "completed";
            var type = stage.Text("stage_type");
            var oral = type == "offer" && (stage.Text("stage_label") == "OC" || item.Raw.Text("offer_status") == "none");
            var formal = type == "offer" && item.Raw.Text("offer_status") is "received" or "accepted" or "declined";
            result.Add(new(stage.Text("id"), oral ? "OC" : stage.Text("stage_label"), stage.Text("entered_at"), oral && formal ? "completed" : state));
            if (oral && formal) result.Add(new("formal", "Offer", CareerNotes.Value("收到日期", item.Raw.Text("notes")), state));
        }
        if (!item.Ended)
        {
            string[] future = item.Stage == "screening" ? ["笔试 / 测评", "面试", "Offer"] : item.Stage is "assessment" or "written_test" ? ["面试", "Offer"] : item.Stage is "interview" or "ai_interview" ? ["Offer"] : [];
            foreach (var label in future) result.Add(new("future:" + label, label, "", "future"));
        }
        return result.ToArray();
    }
}
