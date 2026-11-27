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
    /// <summary>只在个别路径上用的查询键：复盘上下文的 kind / id；记忆反馈与复盘对比按哪场模拟面试或面试取（Mac <c>DesktopTransport.scopedQueryKey</c>）。</summary>
    public static bool ScopedQueryKey(string path, string key) => path switch
    {
        "/api/mock-interviews/review-context" => key is "kind" or "id",
        "/api/memory/feedback" => key is "mock_interview_id" or "interview_session_id" or "kinds",
        "/api/memory/review-comparison" => key is "mock_interview_id" or "interview_session_id",
        _ => false,
    };

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

/// <summary>共享 schema 存在备注里的 V4 字段；不相关的行全部保留。</summary>
public static class CareerNotes
{
    public static readonly string[] Fields = ["投递渠道", "口头薪酬", "收到日期", "回复截止", "薪酬说明", "预计入职", "试用期", "Offer 材料"];

    public static string Value(string field, string notes) =>
        notes.Split('\n').FirstOrDefault(line => SwiftText.HasPrefix(line, field + "：")) is { } line ? line[(field.Length + 1)..] : "";

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
