using DrawOffer.Core.Api;
using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
namespace DrawOffer.Core.Models;

/// <summary>岗位 × 简历匹配结果（`GET /api/job-descriptions/{id}/match` 的 match，Web `JobMatch`）。</summary>
public sealed record JobMatch
{
    public string Status { get; }
    public bool Stale { get; }
    public int? Score { get; }
    public string? Headline { get; }
    public IReadOnlyList<string> Hits { get; }
    public IReadOnlyList<string> Gaps { get; }
    public IReadOnlyList<string> Covered { get; }
    public IReadOnlyList<string> Missing { get; }
    public string? ErrorCode { get; }

    JobMatch(JsonNode value, string status)
    {
        Status = status;
        Stale = value.Bool("stale");
        Score = value.Number("score") is { } score ? (int)score : null;
        Headline = CareerJson.OptionalString(value, "headline") is { Length: > 0 } headline ? headline : null;
        Hits = CareerJson.Strings(value.Get("hits")); Gaps = CareerJson.Strings(value.Get("gaps"));
        Covered = CareerJson.Strings(value.Get("highlights").Get("covered")); Missing = CareerJson.Strings(value.Get("highlights").Get("missing"));
        ErrorCode = CareerJson.OptionalString(value, "error_code");
    }

    /// <summary>Swift `init?(_:)`：不是对象或缺少字符串 `status` 时为 null。</summary>
    public static JobMatch? From(JsonNode? value) =>
        value is JsonObject && CareerJson.OptionalString(value, "status") is { } status ? new JobMatch(value, status) : null;

    public bool Pending => Status == "pending";
    public bool Ready => Status == "ready";

    /// <summary>Web `matchErrorMessage`。</summary>
    public static string ErrorMessage(string? code) => code switch
    {
        "JOB_MATCH_NO_DESCRIPTION" => "请先补充岗位描述。",
        "LLM_MODEL_NOT_CONFIGURED" => "AI 匹配分析暂未开放。",
        "JOB_NOT_FOUND" or "RESUME_NOT_FOUND" => "岗位或简历已不存在，请刷新页面。",
        "JOB_MATCH_INTERRUPTED" => "上次分析被中断，请重新分析。",
        _ => "分析没有完成，请稍后重新分析。",
    };

    /// <summary>前端轮询节奏与 Web 一致：每 3 秒一次，最多 20 次。</summary>
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(3);
    public const int PollLimit = 20;

    public bool Equals(JobMatch? other) => other is not null && Status == other.Status && Stale == other.Stale && Score == other.Score && Headline == other.Headline
        && Hits.SequenceEqual(other.Hits) && Gaps.SequenceEqual(other.Gaps) && Covered.SequenceEqual(other.Covered) && Missing.SequenceEqual(other.Missing) && ErrorCode == other.ErrorCode;
    public override int GetHashCode() => HashCode.Combine(Status, Stale, Score, Headline, ErrorCode);
}

/// <summary>首页推荐岗位（`/api/job-matches/recommendations`）。</summary>
public sealed record JobMatchRecommendations
{
    public sealed record Item(string Id, string Title, string Company, int Score, string? ApplicationStatus);

    public string State { get; }
    public string? ResumeTitle { get; }
    public IReadOnlyList<Item> Items { get; }
    public int PendingCount { get; }
    public bool CanCompute { get; }

    public JobMatchRecommendations(JsonNode value)
    {
        State = value.Text("state");
        ResumeTitle = CareerJson.OptionalString(value.Get("resume"), "title");
        Items = value.Items("items").Select(x => new Item(x.Text("job_id"), x.Text("job_title"), x.Text("company_name"), x.Integer("score"), CareerJson.OptionalString(x, "application_status"))).ToList();
        PendingCount = value.Integer("pending_count");
        CanCompute = value.Bool("can_compute");
    }

    public bool Equals(JobMatchRecommendations? other) => other is not null && State == other.State && ResumeTitle == other.ResumeTitle && Items.SequenceEqual(other.Items) && PendingCount == other.PendingCount && CanCompute == other.CanCompute;
    public override int GetHashCode() => HashCode.Combine(State, ResumeTitle, Items.Count, PendingCount, CanCompute);
}

/// <summary>岗位详情的完整可编辑字段（Web `JobDescriptionFields`）。PUT 需要提交完整字段集合与 base_lock_version。</summary>
public static class JobDescriptionFields
{
    public static readonly string[] OptionalText =
    [
        "logo_url", "employment_type", "education_requirement", "experience_requirement", "work_schedule", "work_city",
        "work_address", "work_mode", "salary_text", "salary_min", "salary_max", "salary_currency", "salary_period",
        "company_legal_name", "company_industry", "company_size", "company_financing_stage", "company_description",
        "recruiter_name", "recruiter_title", "notes",
    ];
    public static readonly (string Value, string Label)[] Employment = [("internship", "实习"), ("campus", "校招"), ("full_time", "正式")];
    public static readonly (string Value, string Label)[] WorkMode = [("onsite", "现场"), ("hybrid", "混合"), ("remote", "远程")];
    public static readonly (string Value, string Label)[] SalaryPeriod = [("hour", "小时"), ("day", "天"), ("month", "月"), ("year", "年")];

    /// <summary>由岗位记录与修改合成 PUT 请求体：可选文本去空白后为空即 null，技能按逗号拆分。</summary>
    public static JsonObject Payload(JsonNode record, IReadOnlyDictionary<string, string> changes)
    {
        string Value(string key)
        {
            if (changes.TryGetValue(key, out var changed)) return changed;
            if (key == "skills") return string.Join(", ", CareerJson.Strings(record.Get("skills")));
            if (key == "salary_months_per_year" && record.Number(key) is { } number) return ((int)number).ToString(System.Globalization.CultureInfo.InvariantCulture);
            return record.Text(key);
        }
        var skills = new JsonArray(SwiftText.Split(Value("skills"), c => c is "," or "，" or "、").Select(SwiftText.TrimAll).Where(x => x.Length > 0).Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
        var fields = new JsonObject
        {
            ["job_title"] = SwiftText.TrimAll(Value("job_title")),
            ["company_name"] = SwiftText.TrimAll(Value("company_name")),
            ["description"] = Value("description"),
            ["skills"] = skills,
            ["base_lock_version"] = (double)(CareerJson.OptionalInteger(record, "lock_version") ?? 1),
        };
        foreach (var key in OptionalText)
        {
            var text = key is "notes" or "company_description" ? Value(key) : SwiftText.TrimAll(Value(key));
            fields[key] = SwiftText.TrimAll(text).Length == 0 ? null : text;
        }
        if (fields["salary_currency"].String() is { } currency) fields["salary_currency"] = currency.ToUpperInvariant();
        fields["salary_months_per_year"] = SwiftText.Int(SwiftText.TrimWhitespaces(Value("salary_months_per_year"))) is { } months ? (double)months : null;
        return fields;
    }

    /// <summary>Mac 的 `APIError.unauthorized` 对应 401 的 <see cref="ApiException"/>；`APIError.server(_, code)` 对应其它状态。</summary>
    public static string ErrorMessage(Exception error, string fallback)
    {
        if (error is not ApiException api) return fallback;
        if (api.Status == HttpStatusCode.Unauthorized) return "登录状态已失效，请重新登录。";
        return api.Code switch
        {
            "JD_NOT_FOUND" => "岗位不存在，或当前账号没有访问权限。",
            "JD_EDIT_CONFLICT" => "岗位内容已经变化，请重新打开后再保存。",
            "INVALID_JOB_DESCRIPTION" => "请检查必填字段、薪资组合和字段长度。",
            _ => fallback,
        };
    }
}
