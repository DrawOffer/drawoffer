using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Xunit;

namespace DrawOffer.Core.Tests;

/// <summary>与 Mac `CareerTests`、`CareerDetailTests`、`MockInterviewTests`、`CoreTests` 中白名单用例逐条相同。</summary>
public sealed class DesktopRoutesTests
{
    const string Base = "/api/mock-interviews/01234567-89ab-4cde-8fab-0123456789ab";

    [Fact]
    public void CareerChannelsHaveNarrowRouteBoundary()
    {
        Assert.True(CareerRequest.Allowed("/api/job-applications/12/stages", "POST"));
        Assert.True(CareerRequest.Allowed("/api/interview-sessions/12/answer-plan", "PUT"));
        foreach (var path in new[] { "/api/account/avatar", "/api/job-applications/12/reviews", "/api/job-applications//12", "/api/job-applications/12/", "/api/job-applications/１２", "/api/job-applications?scope=all" })
            Assert.False(CareerRequest.Allowed(path, "GET"), path);
        Assert.False(CareerRequest.Allowed("/api/resumes/1/semantic-classification", "POST"));
        foreach (var (path, method) in new[]
        {
            ("/api/resumes/1", "DELETE"), ("/api/resumes/1/copy", "POST"), ("/api/resumes/1/share", "PATCH"),
            ("/api/resume-imports/3", "DELETE"), ("/api/resumes/1/apply-template", "POST"), ("/api/resumes/1/assets", "POST"),
            ("/api/resumes/1/assets/a.png", "DELETE"), ("/api/account/profile", "GET"), ("/api/account/user-profile", "PUT"),
            ("/api/agent/sessions", "POST"), ("/api/agent/proposals/abc/confirm", "POST"), ("/api/job-descriptions/2/match", "GET"),
        })
            Assert.True(CareerRequest.Allowed(path, method), $"{method} {path}");
        foreach (var (path, method) in new[]
        {
            ("/api/resumes/1/assets", "GET"), ("/api/resumes/1/apply-template", "GET"), ("/api/account/deletion", "POST"), ("/api/admin/agent-operations", "GET"),
            ("/api/agent/sessions/1/messages", "POST"), ("/api/resumes/abc", "GET"),
        })
            Assert.False(CareerRequest.Allowed(path, method), $"{method} {path}");
        Assert.True(AgentRequest.Streams("/api/agent/sessions/1/messages", "POST"));
    }

    [Fact]
    public void StageDetailRoutesAreNarrow()
    {
        foreach (var (path, method) in new[]
        {
            ("/api/interview-sessions/3/review:generate", "POST"), ("/api/interview-sessions/3/review-notes", "PUT"),
            ("/api/interview-sessions/3/review-notes/9", "DELETE"), ("/api/interview-sessions/3/transcriptions/4:retry", "POST"),
            ("/api/interview-sessions/3/transcriptions/4:apply", "POST"), ("/api/interview-sessions/3/written-questions:extract", "POST"),
            ("/api/interview-sessions/3/assets", "GET"), ("/api/interview-sessions/3", "DELETE"), ("/api/interview-assets/4/content", "GET"),
            ("/api/interview-sessions/3/prep-items:generate", "POST"),
        })
            Assert.True(CareerRequest.Allowed(path, method), $"{method} {path}");
        foreach (var (path, method) in new[]
        {
            ("/api/interview-sessions/3/prep-items:generate", "GET"), ("/api/interview-sessions/3/transcriptions/4:drop", "POST"),
            ("/api/interview-sessions/3/review-notes/x", "DELETE"), ("/api/interview-assets/4", "DELETE"), ("/api/interview-sessions/3/review:generate", "GET"),
        })
            Assert.False(CareerRequest.Allowed(path, method), $"{method} {path}");
    }

    [Fact]
    public void MockInterviewSurfaceMatchesMac()
    {
        foreach (var command in new[] { "answers", "skip", "reply:retry", "finish", "abandon", "retry", "repeat" })
            Assert.True(CareerRequest.Allowed(Base + "/" + command, "POST"));
        Assert.True(CareerRequest.Allowed(Base, "DELETE"));
        foreach (var path in new[] { Base + "/speech", Base + "/transcripts", Base + "/../repeat", Base + "/", Base.ToUpperInvariant(), "/api/mock-interviews/speech-capability" })
            Assert.False(CareerRequest.Allowed(path, "POST"), path);
        Assert.True(CareerRequest.Allowed("/api/datasets", "GET"));
        Assert.True(MockInterviewRequest.Allowed("/api/mock-interviews/speech-capability", "GET"));
        Assert.True(MockInterviewRequest.Allowed(Base + "/questions/12/transcript", "PUT"));
        Assert.True(MockInterviewRequest.Allowed(Base + "/recordings", "DELETE"));
        Assert.False(MockInterviewRequest.Allowed(Base + "/questions/x/recording", "GET"));
        Assert.False(MockInterviewRequest.Allowed(Base + "/questions/12/recording", "DELETE"));
        Assert.True(MockInterviewRequest.Allowed(Base + "/answer-mode", "POST"));
        Assert.True(MockInterviewRequest.Allowed(Base + "/actions/0", "PUT"));
        Assert.True(MockInterviewRequest.Allowed(Base + "/actions/12", "PUT"));
        Assert.False(MockInterviewRequest.Allowed(Base + "/actions/0", "POST"));
        Assert.False(MockInterviewRequest.Allowed(Base + "/actions/x", "PUT"));
        Assert.False(MockInterviewRequest.Allowed(Base + "/actions/1234", "PUT"));
        Assert.False(MockInterviewRequest.Allowed("/api/datasets", "POST"));
        Assert.False(MockInterviewRequest.Allowed("/api/datasets/1", "GET"));
    }

    [Fact]
    public void ParityAllowlistMatchesBackendDesktopRoutes()
    {
        Assert.True(CareerRequest.Allowed("/api/memory/home", "GET"));
        Assert.True(CareerRequest.Allowed("/api/memory/home/disclosures", "POST"));
        Assert.True(CareerRequest.Allowed("/api/announcements/read-all", "POST"));
        Assert.True(CareerRequest.Allowed("/api/billing/summary", "GET"));
        Assert.False(CareerRequest.Allowed("/api/memory/clear", "POST"));
        Assert.False(CareerRequest.Allowed("/api/memory/grants", "GET"));
        Assert.False(CareerRequest.Allowed("/api/billing/summary", "POST"));
        Assert.True(CareerRequest.Allowed("/api/job-pool/companies/12", "GET"));
        Assert.True(CareerRequest.Allowed("/api/job-pool/34/join", "POST"));
        Assert.False(CareerRequest.Allowed("/api/admin/job-pool/sources", "GET"));
        Assert.False(CareerRequest.Allowed("/api/job-pool/abc", "GET"));
    }

    [Fact]
    public void BrowserCallbackAcceptsOnlyTheLoginShape()
    {
        var ok = BrowserCallback.Parse(new Uri("drawoffer://auth/callback?code=abc&state=xyz%3D"));
        Assert.NotNull(ok);
        Assert.Equal("abc", ok["code"]);
        Assert.Equal("xyz=", ok["state"]);
        Assert.Null(BrowserCallback.Parse(new Uri("drawoffer://auth/other?code=a")));
        Assert.Null(BrowserCallback.Parse(new Uri("https://auth/callback?code=a")));
        Assert.Null(BrowserCallback.Parse(new Uri("drawoffer://evil/callback?code=a")));
        Assert.Equal("drawoffer://auth/callback?code=1&state=2", BrowserCallback.FromArguments(["--flag", "drawoffer://auth/callback?code=1&state=2"])?.OriginalString);
        Assert.Null(BrowserCallback.FromArguments(["--flag"]));
    }

    [Fact]
    public void AnnouncementsAndCreditsMatchWeb()
    {
        var list = AnnouncementList.From(JsonNode.Parse("""{"items":[{"id":"1","level":"important","category":"promotion","title":"虚构活动","body":"**限时** [查看](https://example.com) 详情\n\n- 第二行","publishedAt":"2026-10-19T08:00:00Z","read":false}],"unreadCount":1}"""));
        Assert.Equal(1, list.UnreadCount);
        var item = list.Items[0];
        Assert.True(item.Important);
        Assert.Equal("活动福利", item.CategoryLabel);
        Assert.Equal("限时 查看 详情 - 第二行", item.Summary);
        Assert.Equal("免费版", BillingSummary.From(JsonNode.Parse("""{"available":"0"}""")).TierLabel);
        Assert.True(BillingSummary.From(JsonNode.Parse("""{"available":"0"}""")).Exhausted);
        Assert.Equal("1,234.5", BillingSummary.Credits("1234.50"));
        Assert.Equal("-3", BillingSummary.Credits("-3"));
        Assert.Equal("80.58", BillingSummary.From(JsonNode.Parse("""{"tier":"basic","available":80.58}""")).AvailableText);
        Assert.Equal("—", BillingSummary.Credits("abc"));
    }
}
