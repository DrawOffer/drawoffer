using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using DrawOffer.Core.Models;

namespace DrawOffer.Core.Api;

/// <summary>
/// 桌面传输层里 Mac `HTTPAPIClient.swift` 已有、旧 Windows 版缺少的接口：AI 对话 SSE、对话附件、简历导入、简历 PDF、
/// 模拟面试音频与语音 WebSocket。上传参数用原始字节与文件名，避免依赖界面层的上传模型；校验规则与 Mac 相同。
/// </summary>
public sealed partial class DesktopTransport
{
    static ApiException Server(HttpStatusCode status, string code) => new(status, code);

    static async Task<byte[]> ReadLimitedAsync(Stream stream, long limit, CancellationToken ct)
    {
        using var data = new MemoryStream();
        var buffer = new byte[64 * 1024];
        int count;
        while ((count = await stream.ReadAsync(buffer, ct)) > 0)
        {
            if (data.Length + count > limit) throw new InvalidDataException();
            data.Write(buffer, 0, count);
        }
        return data.ToArray();
    }

    /// <summary>错误体是小段 JSON，只读前 16 KiB 取 error 码。</summary>
    static async Task<ApiException> FailureAsync(HttpResponseMessage response, CancellationToken ct)
    {
        if (response.StatusCode == HttpStatusCode.Unauthorized) return Server(response.StatusCode, "UNAUTHORIZED");
        string code = "";
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(ct);
            var buffer = new byte[16 * 1024];
            var read = await stream.ReadAtLeastAsync(buffer, buffer.Length, false, ct);
            code = JsonNode.Parse(buffer.AsSpan(0, read))?.Text("error") ?? "";
        }
        catch { }
        return Server(response.StatusCode, code.Length > 0 ? code : $"HTTP_{(int)response.StatusCode}");
    }

    static void Authorize(HttpRequestMessage request, string? access)
    {
        request.Headers.Add("X-Request-ID", Guid.NewGuid().ToString());
        if (access is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
    }

    /// <summary>
    /// AI 助手的 SSE 流：逐帧回调原始帧文本；回调返回 true（终止事件）即结束，流读完仍未结束视为中断（`AGENT_STREAM_INCOMPLETE`）。
    /// 单帧最多 1 MiB、整条流最多 16 MiB；单次请求超时 5 分钟。
    /// </summary>
    public async Task StreamAgentAsync(string path, string method, JsonNode? body, string? access, Func<string, Task<bool>> onFrame, CancellationToken ct = default)
    {
        if (!AgentRequest.Streams(path, method)) throw new InvalidDataException();
        using var request = new HttpRequestMessage(new HttpMethod(method), path);
        Authorize(request, access);
        request.Headers.Accept.ParseAdd("text/event-stream");
        if (body is not null) request.Content = JsonContent.Create(body);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(5));
        using var response = await _fileHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (response.StatusCode != HttpStatusCode.OK) throw await FailureAsync(response, deadline.Token);
        if (response.Content.Headers.ContentType?.MediaType != "text/event-stream") throw new InvalidDataException();
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
        var frame = new MemoryStream();
        var buffer = new byte[8192];
        long total = 0;
        byte previous = 0;
        int count;
        while ((count = await stream.ReadAsync(buffer, deadline.Token)) > 0)
        {
            for (var i = 0; i < count; i++)
            {
                var b = buffer[i];
                if (++total > 16 * 1024 * 1024 || frame.Length > 1024 * 1024) throw new InvalidDataException();
                if (b == 0x0A && previous == 0x0A)
                {
                    if (await onFrame(Encoding.UTF8.GetString(frame.ToArray()))) return;
                    frame.SetLength(0);
                    previous = 0;
                    continue;
                }
                if (b != 0x0D) { frame.WriteByte(b); previous = b; }
            }
        }
        throw Server(HttpStatusCode.BadGateway, "AGENT_STREAM_INCOMPLETE");
    }

    /// <summary>对话附件：multipart `file` 字段，`Idempotency-Key` 为附件 id；单个最多 10 MiB，响应最多 1 MiB。</summary>
    public async Task<JsonNode> UploadAgentAttachmentAsync(string session, string fileName, byte[] content, string id, string? access, CancellationToken ct = default)
    {
        var path = $"/api/agent/sessions/{session}/attachments";
        if (!AgentRequest.Allowed(path, "POST")) throw new InvalidDataException();
        if (content.Length > AgentAttachments.MaxBytes) throw Server(HttpStatusCode.RequestEntityTooLarge, "AGENT_ATTACHMENT_TOO_LARGE");
        using var request = new HttpRequestMessage(HttpMethod.Post, path);
        Authorize(request, access);
        request.Headers.Add("Idempotency-Key", id);
        var form = new MultipartFormDataContent("DrawOffer-" + Guid.NewGuid());
        var file = new ByteArrayContent(content);
        file.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        form.Add(file, "file", fileName);
        request.Content = form;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(5));
        using var response = await _fileHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (!response.IsSuccessStatusCode) throw await FailureAsync(response, deadline.Token);
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
        return JsonNode.Parse(await ReadLimitedAsync(stream, 1024 * 1024, deadline.Token)) ?? new JsonObject();
    }

    /// <summary>`POST /api/resumes/import`：multipart 上传文件（可带 `template_id`），`Idempotency-Key` 固定为本次导入的 UUID，重试不重复受理。</summary>
    public async Task<JsonNode> ImportResumeAsync(string fileName, string contentType, byte[] content, string? templateId, string idempotencyKey, string? access, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/resumes/import");
        Authorize(request, access);
        request.Headers.Add("Idempotency-Key", idempotencyKey);
        var form = new MultipartFormDataContent("DrawOffer-" + Guid.NewGuid());
        var file = new ByteArrayContent(content);
        file.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        form.Add(file, "file", fileName.Replace("\"", "_").Replace("\r", "").Replace("\n", ""));
        if (templateId is not null) form.Add(new StringContent(templateId), "template_id");
        request.Content = form;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(3));
        using var response = await _fileHttp.SendAsync(request, deadline.Token);
        if (!response.IsSuccessStatusCode) throw await FailureAsync(response, deadline.Token);
        return await response.Content.ReadFromJsonAsync<JsonNode>(deadline.Token) ?? new JsonObject();
    }

    /// <summary>
    /// `GET /api/resumes/{id}/pdf?lock_version=`：服务端按当前版本生成 PDF，版本过期返回 409。
    /// 流式读取并同时校验 MIME、声明大小、实际大小与 `%PDF-` 文件头，不落盘。
    /// </summary>
    public async Task<byte[]> DownloadResumePdfAsync(string id, int lockVersion, int limit, string? access, CancellationToken ct = default)
    {
        if (id.Length is 0 or > 20 || !id.All(char.IsAsciiDigit) || lockVersion <= 0 || limit <= 0) throw new InvalidDataException();
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/resumes/{id}/pdf?lock_version={lockVersion}");
        Authorize(request, access);
        request.Headers.Accept.ParseAdd("application/pdf");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(3));
        using var response = await _fileHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (response.StatusCode != HttpStatusCode.OK) throw await FailureAsync(response, deadline.Token);
        if (response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant() != "application/pdf" || response.Content.Headers.ContentLength > limit) throw new InvalidDataException();
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
        var data = await ReadLimitedAsync(stream, limit, deadline.Token);
        if (data.Length < 5 || Encoding.ASCII.GetString(data, 0, 5) != "%PDF-") throw new InvalidDataException();
        return data;
    }

    /// <summary>模拟面试的二进制音频：试听 mp3 与录音 wav，最多 16 MiB，只在内存中交给播放器。</summary>
    public async Task<byte[]> MockAudioAsync(string path, string method, JsonNode? body, string? access, CancellationToken ct = default)
    {
        if (!MockInterviewRequest.Audio(path, method)) throw new InvalidDataException();
        using var request = new HttpRequestMessage(new HttpMethod(method), path);
        Authorize(request, access);
        request.Headers.Accept.ParseAdd("audio/mpeg, audio/wav");
        if (body is not null) request.Content = JsonContent.Create(body);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(2));
        using var response = await _fileHttp.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        const int limit = 16 * 1024 * 1024;
        if (response.StatusCode != HttpStatusCode.OK) throw await FailureAsync(response, deadline.Token);
        var type = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant();
        if (type is not ("audio/mpeg" or "audio/wav" or "audio/x-wav" or "audio/wave") || response.Content.Headers.ContentLength > limit) throw new InvalidDataException();
        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
        return await ReadLimitedAsync(stream, limit, deadline.Token);
    }

    /// <summary>
    /// 实时语音识别 WebSocket：`/api/mock-interviews/{id}/speech?question_id=&amp;purpose=`，握手携带 desktop Bearer。
    /// 作答与输入框语音带题号；设备检测试读一句不带题号（结果不保存、不能用来提交回答）。
    /// </summary>
    public static bool SpeechQueryAllowed(IReadOnlyDictionary<string, string> query)
    {
        var question = query.GetValueOrDefault("question_id") ?? "";
        var numeric = question.Length > 0 && question.All(char.IsAsciiDigit);
        return query.GetValueOrDefault("purpose") switch
        {
            "voice_input" or "voice_answer" => numeric && query.Count == 2,
            "device_check" => query.Count == 1,
            _ => false,
        };
    }

    public async Task<ClientWebSocket> SpeechSocketAsync(string interviewId, IReadOnlyDictionary<string, string> query, string? access, CancellationToken ct = default)
    {
        if (!Guid.TryParseExact(interviewId, "D", out var id) || id.ToString("D") != interviewId || !SpeechQueryAllowed(query)) throw new InvalidDataException();
        var builder = new UriBuilder(new Uri(Origin, $"/api/mock-interviews/{interviewId}/speech"))
        {
            Scheme = Origin.Scheme == "https" ? "wss" : "ws",
            Query = string.Join("&", query.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => Uri.EscapeDataString(x.Key) + "=" + Uri.EscapeDataString(x.Value))),
        };
        var socket = new ClientWebSocket();
        if (access is not null) socket.Options.SetRequestHeader("Authorization", "Bearer " + access);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        await socket.ConnectAsync(builder.Uri, deadline.Token);
        return socket;
    }
}

/// <summary>对话附件规则（Mac `AgentAttachmentUpload`）：类型、大小、数量上限与错误提示。</summary>
public static class AgentAttachments
{
    public const int MaxBytes = 10 * 1024 * 1024;
    public const int MaxFiles = 10;
    public const int MaxTotalBytes = 30 * 1024 * 1024;
    public static readonly string[] Extensions = ["png", "jpg", "jpeg", "webp", "pdf", "docx", "md", "txt", "mp3", "wav", "m4a", "ogg", "webm"];

    /// <summary>校验用户选择的文件；不通过时抛出与后端相同的错误码。</summary>
    public static void Validate(string name, long size)
    {
        var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        if (!Extensions.Contains(ext) || name.Any(c => "\r\n\"\\/".Contains(c))) throw new ApiException(HttpStatusCode.UnsupportedMediaType, "AGENT_ATTACHMENT_TYPE_UNSUPPORTED");
        if (size <= 0) throw new ApiException(HttpStatusCode.BadRequest, "AGENT_ATTACHMENT_EMPTY");
        if (size > MaxBytes) throw new ApiException(HttpStatusCode.RequestEntityTooLarge, "AGENT_ATTACHMENT_TOO_LARGE");
    }

    /// <summary>与 Web `chatFileKind` 相同的分类。</summary>
    public static string Kind(string name)
    {
        var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        return ext is "png" or "jpg" or "jpeg" or "webp" ? "image" : ext is "mp3" or "wav" or "m4a" or "ogg" or "webm" ? "audio" : "document";
    }

    public static string ErrorMessage(Exception error) => (error as ApiException)?.Code switch
    {
        "AGENT_ATTACHMENT_TYPE_UNSUPPORTED" => "不支持这种文件类型。",
        "AGENT_ATTACHMENT_TOO_LARGE" => "单个文件不能超过 10 MB。",
        "AGENT_ATTACHMENT_EMPTY" => "文件是空的。",
        "AGENT_ATTACHMENT_LIMIT_REACHED" => "一次最多附加 10 个文件。",
        _ => "上传失败，请重试。",
    };
}
