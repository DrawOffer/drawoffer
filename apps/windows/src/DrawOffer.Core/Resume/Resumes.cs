using System.Text.Json.Nodes;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>Mac `Resumes.swift` 中白名单以外的部分（白名单、退役模板与数量上限在 DesktopRoutes.cs）。</summary>
public static partial class ResumeRequest
{
    /// <summary>与 Web `defaultResumeOf` 相同：服务端指定的默认简历；没有时取 id 最小（最早创建）的一份。</summary>
    public static ResumeSummary? DefaultResume(IReadOnlyList<ResumeSummary> resumes, string? defaultID)
    {
        if (defaultID is not null && resumes.FirstOrDefault(x => x.Id == defaultID) is { } chosen) return chosen;
        // Swift 比较 (id.count, id)：先比字素数，再按 Unicode 标量序比字符串；并列保留最先的。
        return S.MinBy(resumes, (a, b) =>
        {
            int ca = S.Count(a.Id), cb = S.Count(b.Id);
            return ca != cb ? ca < cb : S.Cmp(a.Id, b.Id) < 0;
        });
    }

    static readonly Dictionary<string, string> Messages = new()
    {
        ["INVALID_RESUME_TITLE"] = "名称无效，请输入 1–255 个字符且不含换行。",
        ["RESUME_TITLE_CONFLICT"] = "已有同名简历，请换一个名称。",
        ["RESUME_LIMIT_REACHED"] = "已达简历数量上限，删除不用的简历后再试。",
        ["TEMPLATE_INACTIVE"] = "这套模板已下线，请刷新模板列表后重选。",
        ["TEMPLATE_REQUIRED"] = "请先选择模板。",
        ["RESUME_EDIT_CONFLICT"] = "简历已在其他设备更新，请刷新列表后重试。",
        ["RESUME_COPY_REQUEST_CONFLICT"] = "这次复制请求已用于其他操作，请重新复制。",
        ["RESUME_NOT_FOUND"] = "这份简历已不存在，请刷新列表。",
        ["SHARE_LINK_UNAVAILABLE"] = "分享链接已不存在，请重新创建。",
        ["IMAGE_TOO_LARGE"] = "图片不能超过 10 MB。",
        ["INVALID_IMAGE"] = "只支持 PNG 或 JPEG 图片。",
        ["ASSET_UPLOAD_FAILED"] = "图片上传失败，请稍后重试。",
        ["DESKTOP_ROUTE_FORBIDDEN"] = "当前服务尚未开放桌面端此操作，请更新服务端后重试。",
    };

    /// <summary>401 → 登录失效；其余服务端错误按错误码给文案，未知码用 fallback；非服务端错误用 fallback。</summary>
    public static string ErrorMessage(Exception error, string fallback)
    {
        if (S.IsUnauthorized(error)) return "登录已失效，请重新登录。";
        if (!S.IsServer(error, out _, out var code)) return fallback;
        return Messages.TryGetValue(code, out var message) ? message : fallback;
    }
}

/// <summary>`GET/POST/PATCH /api/resumes/{id}/share` 的 share 对象。</summary>
public sealed record ResumeShare(string Token, bool IsPublic, DateTimeOffset? ExpiresAt, bool AllowDownload, DateTimeOffset? CreatedAt)
{
    /// <summary>不是对象或没有 share_token 时为 null；share_allow_download 不是布尔值时默认允许下载。</summary>
    public static ResumeShare? From(JsonNode? value)
    {
        if (value is not JsonObject || value.Get("share_token").String() is not { Length: > 0 } token) return null;
        var allow = value.Get("share_allow_download") is JsonValue flag && flag.GetValueKind() is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False
            ? flag.GetValueKind() == System.Text.Json.JsonValueKind.True : true;
        return new ResumeShare(token, value.Get("share_visibility").String() == "public",
            value.Get("share_expires_at").String() is { } expires ? ResumeSummary.ParseTimestamp(expires) : null, allow,
            value.Get("share_created_at").String() is { } created ? ResumeSummary.ParseTimestamp(created) : null);
    }

    public bool IsExpired(DateTimeOffset? now = null) => ExpiresAt is { } expires && expires <= (now ?? DateTimeOffset.UtcNow);

    /// <summary>Web `shareUrl`：站点 origin 与 API origin 相同，链接为 `{origin}/share/{token}`（token 按路径编码）。</summary>
    public Uri Url(Uri origin)
    {
        var path = origin.AbsolutePath.TrimEnd('/') + "/share/" + S.EscapePath(Token);
        return new UriBuilder(origin) { Path = path }.Uri;
    }

    /// <summary>Web 重新生成规则：未过期保留原到期时间；已过期按原有效时长顺延，推算不出时默认 7 天。</summary>
    public DateTimeOffset? RegeneratedExpiry(DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        if (ExpiresAt is not { } expires || expires > current) return ExpiresAt;
        if (CreatedAt is { } created && created < expires) return current + (expires - created);
        return S.Adding(current, 7 * 86_400);
    }

    /// <summary>ISO 8601 带毫秒（UTC，`Z` 结尾）；没有日期时为 JSON null。毫秒按 Apple 的方式四舍五入。</summary>
    public static JsonNode? Encode(DateTimeOffset? date)
    {
        if (date is not { } value) return null;
        var utc = value.ToUniversalTime();
        var rounded = new DateTimeOffset((utc.UtcTicks + 5_000) / 10_000 * 10_000, TimeSpan.Zero);
        return JsonValue.Create(rounded.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture));
    }
}

/// <summary>一次简历文件导入（Markdown / DOCX / PDF，最多 10 MiB）。读取后整份放在内存，不落盘。</summary>
public sealed class ResumeImportUpload
{
    public string FileName { get; }
    public string ContentType { get; }
    public byte[] Content { get; }
    public string? TemplateID { get; }
    public string IdempotencyKey { get; }

    public const int MaximumBytes = 10 * 1024 * 1024;
    public static readonly IReadOnlyDictionary<string, string> Types = new Dictionary<string, string>
    {
        ["md"] = "text/markdown", ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document", ["pdf"] = "application/pdf",
    };

    /// <summary>
    /// 读取用户选择的文件并做与后端一致的前置校验；不通过时抛出对应错误码的 <see cref="Api.ApiException"/>。
    /// `title` 不为空时与 Web `buildNamedImportFile` 一致：上传文件名改为“标题 + 原扩展名”，后端据此命名简历。
    /// </summary>
    public ResumeImportUpload(string file, string? templateID, string? title = null, string? idempotencyKey = null)
    {
        var ext = PathExtension(file).ToLowerInvariant();
        if (!Types.TryGetValue(ext, out var type)) throw new Api.ApiException((System.Net.HttpStatusCode)415, "UNSUPPORTED_IMPORT_FORMAT");
        byte[] data;
        using (var stream = File.OpenRead(file))
        {
            var buffer = new byte[MaximumBytes + 1];
            var total = 0;
            int read;
            while (total < buffer.Length && (read = stream.Read(buffer, total, buffer.Length - total)) > 0) total += read;
            data = buffer[..total];
        }
        if (data.Length == 0) throw new Api.ApiException(System.Net.HttpStatusCode.BadRequest, "EMPTY_IMPORT_FILE");
        if (data.Length > MaximumBytes) throw new Api.ApiException((System.Net.HttpStatusCode)413, "IMPORT_FILE_TOO_LARGE");
        var named = title is null ? "" : S.Trimmed(title);
        FileName = named.Length == 0 ? Path.GetFileName(file) : named + "." + ext;
        ContentType = type; Content = data;
        TemplateID = templateID;
        IdempotencyKey = idempotencyKey ?? Guid.NewGuid().ToString("D");
    }

    /// <summary>
    /// `URL.pathExtension`：最后一段里最后一个“.”之后的部分；“.”在开头（隐藏文件）或在末尾时为空，
    /// 扩展名里有空格时也为空（与实测的 Foundation 行为相同）。
    /// </summary>
    internal static string PathExtension(string file)
    {
        var name = Path.GetFileName(file.TrimEnd('/'));
        var dot = name.LastIndexOf('.');
        if (dot <= 0 || dot == name.Length - 1) return "";
        var ext = name[(dot + 1)..];
        return ext.Any(char.IsWhiteSpace) ? "" : ext;
    }

    /// <summary>与 Web `validateImportTitle` 相同：不能为空，不能含路径符号或控制字符。</summary>
    public static string? TitleError(string title)
    {
        var value = S.Trimmed(title);
        if (value.Length == 0) return "请输入简历名称。";
        if (value.Contains('/') || value.Contains('\\') || value.Any(c => c < 32)) return "简历名称不能包含路径符号或控制字符。";
        return null;
    }

    static readonly Dictionary<string, string> Messages = new()
    {
        ["UNSUPPORTED_IMPORT_FORMAT"] = "只支持 Markdown、DOCX 和 PDF 文件。",
        ["EMPTY_IMPORT_FILE"] = "文件是空的，请换一个文件。",
        ["IMPORT_FILE_TOO_LARGE"] = "文件超过 10 MB，请压缩后再导入。",
        ["IMPORT_CONTENT_INVALID"] = "文件内容无法读取，请检查文件后重试。",
        ["INVALID_IMPORT_FILENAME"] = "文件名无效，请重命名后再导入。",
        ["STRUCTURING_INPUT_TOO_LARGE"] = "文件内容过长，请精简后再导入。",
        ["TEMPLATE_INACTIVE"] = "默认模板暂不可用，请稍后再试。",
        ["RESUME_LIMIT_REACHED"] = "已达简历数量上限，删除不用的简历后再导入。",
        ["RESUME_LAYOUT_UNSUPPORTED"] = "文件版式暂不支持自动导入，请换成更简单的版式。",
    };

    public static string ErrorMessage(Exception error)
    {
        if (S.IsUnauthorized(error)) return "登录已失效，请重新登录。";
        if (!S.IsServer(error, out _, out var code)) return "上传中断，结果尚未确认。请刷新列表查看导入任务。";
        return Messages.TryGetValue(code, out var message) ? message : $"导入失败（{code}），请稍后重试。";
    }
}
