using System.Net;
using System.Net.Sockets;
using System.Text;
using DrawOffer.Core.Api;
using Xunit;

namespace DrawOffer.Core.Tests;

/// <summary>新增传输接口的边界：SSE 分帧与中断、PDF 文件头、语音查询参数、附件规则。</summary>
public sealed class TransportExtrasTests
{
    /// <summary>本地一次性 HTTP 服务：返回给定的状态行、头与正文，记录收到的请求头。</summary>
    static (Uri origin, Task<string> request) Serve(string status, string type, byte[] body)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var origin = new Uri($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/");
        var request = Task.Run(async () =>
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            using var client = await listener.AcceptTcpClientAsync(timeout.Token);
            await using var stream = client.GetStream();
            var bytes = new byte[8192];
            var text = new StringBuilder();
            while (!text.ToString().Contains("\r\n\r\n", StringComparison.Ordinal))
            {
                var count = await stream.ReadAsync(bytes, timeout.Token);
                if (count == 0) break;
                text.Append(Encoding.UTF8.GetString(bytes, 0, count));
            }
            var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(head, timeout.Token);
            await stream.WriteAsync(body, timeout.Token);
            listener.Stop();
            return text.ToString();
        });
        return (origin, request);
    }

    [Fact]
    public async Task AgentStreamSplitsFramesAndStopsAtTerminalEvent()
    {
        var body = Encoding.UTF8.GetBytes("event: run.started\r\ndata: {\"a\":1}\r\n\r\nevent: run.completed\ndata: {}\n\nevent: assistant.delta\ndata: {}\n\n");
        var (origin, request) = Serve("200 OK", "text/event-stream", body);
        using var transport = new DesktopTransport(origin, allowLocalHttp: true);
        var frames = new List<string>();
        await transport.StreamAgentAsync("/api/agent/sessions/s1/messages", "POST", new System.Text.Json.Nodes.JsonObject(), "fixture-access",
            frame => { frames.Add(frame); return Task.FromResult(frame.Contains("run.completed")); }, TestContext.Current.CancellationToken);
        // 与 Mac 相同：空行前的那个换行留在帧末尾，`\r` 被丢弃
        Assert.Equal(["event: run.started\ndata: {\"a\":1}\n", "event: run.completed\ndata: {}\n"], frames);
        var sent = await request;
        Assert.Contains("Bearer fixture-access", sent);
        Assert.Contains("Accept: text/event-stream", sent);
    }

    [Fact]
    public async Task AgentStreamWithoutTerminalEventIsIncomplete()
    {
        var (origin, _) = Serve("200 OK", "text/event-stream", Encoding.UTF8.GetBytes("event: run.started\ndata: {}\n\n"));
        using var transport = new DesktopTransport(origin, allowLocalHttp: true);
        var error = await Assert.ThrowsAsync<ApiException>(() => transport.StreamAgentAsync("/api/agent/sessions/s1/messages", "POST", null, null,
            _ => Task.FromResult(false), TestContext.Current.CancellationToken));
        Assert.Equal("AGENT_STREAM_INCOMPLETE", error.Code);
        await Assert.ThrowsAsync<InvalidDataException>(() => transport.StreamAgentAsync("/api/agent/sessions", "GET", null, null, _ => Task.FromResult(true), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ResumePdfChecksTypeAndHeader()
    {
        var (origin, request) = Serve("200 OK", "application/pdf", Encoding.ASCII.GetBytes("%PDF-1.7 fixture"));
        using var transport = new DesktopTransport(origin, allowLocalHttp: true);
        var data = await transport.DownloadResumePdfAsync("12", 3, 1024, null, TestContext.Current.CancellationToken);
        Assert.Equal("%PDF-", Encoding.ASCII.GetString(data, 0, 5));
        Assert.Contains("GET /api/resumes/12/pdf?lock_version=3 ", await request);

        var (bad, _) = Serve("200 OK", "application/pdf", Encoding.ASCII.GetBytes("not a pdf"));
        using var other = new DesktopTransport(bad, allowLocalHttp: true);
        await Assert.ThrowsAsync<InvalidDataException>(() => other.DownloadResumePdfAsync("12", 3, 1024, null, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<InvalidDataException>(() => other.DownloadResumePdfAsync("abc", 3, 1024, null, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ConflictCarriesServerErrorCode()
    {
        var (origin, _) = Serve("409 Conflict", "application/json", Encoding.UTF8.GetBytes("{\"error\":\"RESUME_VERSION_CONFLICT\"}"));
        using var transport = new DesktopTransport(origin, allowLocalHttp: true);
        var error = await Assert.ThrowsAsync<ApiException>(() => transport.DownloadResumePdfAsync("12", 3, 1024, null, TestContext.Current.CancellationToken));
        Assert.Equal(HttpStatusCode.Conflict, error.Status);
        Assert.Equal("RESUME_VERSION_CONFLICT", error.Code);
    }

    /// <summary>与 Mac `speechQueryAllowed` 测试相同的组合。</summary>
    [Fact]
    public void SpeechQueryMatchesMac()
    {
        Assert.True(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["question_id"] = "12", ["purpose"] = "voice_answer" }));
        Assert.True(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["question_id"] = "12", ["purpose"] = "voice_input" }));
        Assert.True(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["purpose"] = "device_check" }));
        Assert.False(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["question_id"] = "12", ["purpose"] = "device_check" }));
        Assert.False(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["question_id"] = "x", ["purpose"] = "voice_answer" }));
        Assert.False(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["purpose"] = "voice_answer" }));
        Assert.False(DesktopTransport.SpeechQueryAllowed(new Dictionary<string, string> { ["purpose"] = "other" }));
    }

    [Fact]
    public void AttachmentRulesMatchMac()
    {
        AgentAttachments.Validate("简历.pdf", 10);
        Assert.Equal("AGENT_ATTACHMENT_TYPE_UNSUPPORTED", Assert.Throws<ApiException>(() => AgentAttachments.Validate("a.exe", 10)).Code);
        Assert.Equal("AGENT_ATTACHMENT_TYPE_UNSUPPORTED", Assert.Throws<ApiException>(() => AgentAttachments.Validate("a\".pdf", 10)).Code);
        Assert.Equal("AGENT_ATTACHMENT_EMPTY", Assert.Throws<ApiException>(() => AgentAttachments.Validate("a.pdf", 0)).Code);
        Assert.Equal("AGENT_ATTACHMENT_TOO_LARGE", Assert.Throws<ApiException>(() => AgentAttachments.Validate("a.pdf", AgentAttachments.MaxBytes + 1)).Code);
        Assert.Equal("image", AgentAttachments.Kind("x.WEBP"));
        Assert.Equal("audio", AgentAttachments.Kind("x.m4a"));
        Assert.Equal("document", AgentAttachments.Kind("x.md"));
        Assert.Equal("单个文件不能超过 10 MB。", AgentAttachments.ErrorMessage(new ApiException(HttpStatusCode.RequestEntityTooLarge, "AGENT_ATTACHMENT_TOO_LARGE")));
        Assert.Equal("上传失败，请重试。", AgentAttachments.ErrorMessage(new IOException()));
    }
}
