using System.Text.RegularExpressions;

namespace DrawOffer.Core.Models;

/// <summary>路径校验共用：只接受 `/api/` 开头、不含 `//`、`?`、`#`、`..`、不以 `/` 结尾的路径（与 Mac 各白名单的前置检查相同）。</summary>
internal static class RouteGuard
{
    public static bool Clean(string path, string prefix = "/api/") =>
        path.StartsWith(prefix, StringComparison.Ordinal) && !path.Contains("//") && !path.EndsWith('/') && !path.Contains('?') && !path.Contains('#') && !path.Contains("..");

    public static bool Digits(string value, int max = 20) => value.Length > 0 && value.Length <= max && value.All(c => c is >= '0' and <= '9');

    /// <summary>Mac AgentRequest/ResumeRequest 的 id：1–64 位 ASCII 字母、数字、`-`、`_`。</summary>
    public static bool Slug(string value) => value.Length is > 0 and <= 64 && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');

    public static string[] Parts(string path) => path.Split('/', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Mac `Workspace.swift` 的 `ParityRequest`：与后端 `DESKTOP_WORKSPACE_ROUTES` 对齐的公告、额度、记忆、岗位广场。</summary>
public static class ParityRequest
{
    static readonly (string[] Methods, Regex Pattern)[] Routes = new (string[], string)[]
    {
        (["GET"], "/api/announcements"),
        (["GET"], "/api/announcements/unread-count"),
        (["POST"], "/api/announcements/read-all"),
        (["DELETE"], "/api/announcements/[A-Za-z0-9_-]{1,64}"),
        (["GET"], "/api/notifications(/unread-count|/preferences)?"),
        (["PUT"], "/api/notifications/preferences"),
        (["POST"], "/api/notifications/(read-all|[A-Za-z0-9_-]{1,64}/(read|open))"),
        (["DELETE"], "/api/notifications/[A-Za-z0-9_-]{1,64}"),
        (["GET", "POST"], "/api/account/api-keys"),
        (["DELETE"], "/api/account/api-keys/[1-9][0-9]{0,19}"),
        (["GET"], "/api/billing/(summary|ledger|feature-prices|invite-code|invite-rewards)"),
        (["POST"], "/api/billing/invite-codes/check"),
        (["GET"], "/api/memory/(home|home/graph|atlas|outline|overview|brief|match-evidence|checkins|constraints|review-links|review-repeats|review-comparison|feedback)"),
        (["POST"], "/api/memory/(home/disclosures|checkins|constraints)"),
        (["DELETE"], "/api/memory/constraints/[A-Za-z0-9_-]{1,64}"),
        (["GET"], "/api/job-pool(/filters|/companies|/companies/page|/companies/[1-9][0-9]{0,19}|/[1-9][0-9]{0,19})?"),
        (["POST"], "/api/job-pool/[1-9][0-9]{0,19}/join"),
    }.Select(x => (x.Item1, new Regex("^" + x.Item2 + "$", RegexOptions.CultureInvariant))).ToArray();

    public static bool Allowed(string path, string method) => Routes.Any(x => x.Methods.Contains(method) && x.Pattern.IsMatch(path));
}

/// <summary>Mac `Account.swift` 的 `AccountRequest`：资料、昵称、联系邮箱、偏好、头像与求职画像；桌面端不提供密码、微信绑定与注销。</summary>
public static class AccountRequest
{
    public static bool Allowed(string path, string method) => path switch
    {
        "/api/account/profile" or "/api/account/preferences" => method is "GET" or "PATCH",
        "/api/account/contact-email" => method == "PUT",
        "/api/account/user-profile" => method is "GET" or "PUT",
        "/api/account/avatar" => method is "PUT" or "DELETE",
        "/api/account/career-profile" => method is "GET" or "PUT",
        "/api/account/career-profile/read-resume" => method == "POST",
        _ => false,
    };
}

/// <summary>Mac `Resumes.swift` 的 `ResumeRequest`：新建、导入、编辑、切换模板、图片、重命名、复制、删除、分享、默认简历、写作引导与段落聚焦。</summary>
public static partial class ResumeRequest
{
    public static bool Allowed(string path, string method)
    {
        if (!RouteGuard.Clean(path)) return false;
        if (path == "/api/resumes") return method is "GET" or "POST";
        if (path is "/api/resumes/capacity" or "/api/resume-overview") return method == "GET";
        if (path.StartsWith("/api/resume-templates/", StringComparison.Ordinal))
            return method == "GET" && RouteGuard.Digits(path["/api/resume-templates/".Length..]);
        if (path.StartsWith("/api/resume-imports/", StringComparison.Ordinal))
            return RouteGuard.Digits(path["/api/resume-imports/".Length..]) && method is "GET" or "DELETE";
        var p = RouteGuard.Parts(path);
        if (p.Length < 3 || p[0] != "api" || p[1] != "resumes" || !RouteGuard.Digits(p[2])) return false;
        if (p.Length == 3) return method is "GET" or "PUT" or "DELETE";
        if (p.Length == 5 && p[3] == "assets") return method == "DELETE" && p[4].Length is > 0 and <= 255;
        if (p.Length == 5 && p[3] == "guide") return method == "POST" && p[4] is "writes" or "skills:compose" or "experience:compose" or "profile:compose";
        if (p.Length == 7 && p[3] == "section-reviews" && p[5] == "items") return method == "PATCH" && RouteGuard.Slug(p[4]) && RouteGuard.Slug(p[6]);
        if (p.Length != 4) return false;
        return p[3] switch
        {
            "copy" or "apply-template" or "assets" => method == "POST",
            "share" => method is "GET" or "POST" or "PATCH" or "DELETE",
            "default" => method == "PUT",
            "guide" => method is "GET" or "PUT" or "PATCH",
            "section-review:analyze" or "section-review:rewrite" or "review:check" => method == "POST",
            "section-reviews" => method == "GET",
            _ => false,
        };
    }

    /// <summary>Web `RETIRED_RESUME_TEMPLATE_KEYS`。</summary>
    public static readonly HashSet<string> RetiredTemplateKeys = ["blank-cn"];

    /// <summary>Web `MAX_RESUMES_PER_USER`（每人最多 20 份），仅用于提前禁用按钮。</summary>
    public const int MaximumPerUser = 20;
}

/// <summary>Mac `Agent.swift` 的 `AgentRequest`：用户侧 `/api/agent/*`。</summary>
public static class AgentRequest
{
    public static bool Allowed(string path, string method)
    {
        if (!RouteGuard.Clean(path, "/api/agent/")) return false;
        var p = RouteGuard.Parts(path).Skip(2).ToArray();
        bool Id(string value) => RouteGuard.Slug(value);
        switch (p.Length)
        {
            case 1:
                return p[0] is "readiness" or "model" or "models" or "contexts" or "proposals" && method == "GET"
                    || p[0] == "sessions" && method is "GET" or "POST";
            case 2:
                if (p[0] == "sessions") return Id(p[1]) && method is "GET" or "PATCH" or "DELETE";
                if (p[0] == "cards") return p[1] is "credit" or "plans" && method == "GET";
                if (p[0] == "actions") return Id(p[1]) && method == "POST";
                if (p[0] == "tickets") return Id(p[1]) && method == "GET";
                return false;
            case 3:
                if (p[0] == "sessions" && Id(p[1]))
                    return p[2] == "active-run" && method == "GET" || p[2] == "messages" && method == "POST"
                        || p[2] == "attachments" && method is "GET" or "POST" || p[2] == "compact" && method == "POST"
                        || p[2] == "memory" && method == "GET";
                if (p[0] == "runs" && Id(p[1])) return p[2] == "events" && method == "GET" || p[2] is "cancel" or "steer" && method == "POST";
                if (p[0] == "proposals" && Id(p[1])) return p[2] is "confirm" or "reject" && method == "POST";
                return false;
            case 4:
                if (p[0] == "sessions" && Id(p[1]) && p[2] == "submissions") return Id(p[3]) && method == "GET";
                if (p[0] == "sessions" && Id(p[1]) && p[2] == "attachments") return Id(p[3]) && method == "DELETE";
                if (p[0] == "sessions" && Id(p[1]) && p[2] == "memory") return p[3] == "recorded" && method == "GET";
                if (p[0] == "runs" && Id(p[1]) && p[2] == "steer") return Id(p[3]) && method == "GET";
                return false;
            case 5:
                if (p[0] == "sessions" && Id(p[1]) && p[2] == "attachments" && Id(p[3]))
                    return p[4] == "retry" && method == "POST" || p[4] == "file" && method == "GET";
                return false;
            default:
                return false;
        }
    }

    /// <summary>流式接口：发送消息、整理对话与重新接入进行中的运行。</summary>
    public static bool Streams(string path, string method) =>
        Allowed(path, method) && (method == "POST" && (path.EndsWith("/messages") || path.EndsWith("/compact")) || method == "GET" && path.EndsWith("/events"));
}
