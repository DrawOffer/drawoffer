using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Home;
using DrawOffer.Core.Models;
using Xunit;

namespace DrawOffer.Core.Tests;

/// <summary>首页选屏、最近进展文字、图谱摆放，以及简历更新时间与 AI 事件（数据均为虚构）。</summary>
public sealed class HomeTests
{
    static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
    static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-31T02:00:00Z", CultureInfo.InvariantCulture);

    static JsonNode J(string source) => JsonNode.Parse(source)!;

    static readonly string Preview = """{"identity":{"node_id":"node_identity","name":{"value":"林晓"},"headline":{"value":"后端开发 · 2026 届"},"contacts":[{"value":"13912345678"},{"value":"lin@fixture.dev"}]},"sections":[]}""";

    static List<ResumeSummary> Summaries() =>
    [
        ResumeSummary.From(J("""{"id":"2","title":"旧","source_type":"template","lock_version":1,"created_at":"2026-10-01T00:00:00","updated_at":"2026-10-01T00:00:00","preview":null}"""))!,
        ResumeSummary.From(J("""{"id":"3","title":"新","source_type":"template","lock_version":1,"created_at":"2026-10-01T00:00:00","updated_at":"2026-10-30T08:00:00","preview":{"data":""" + Preview + ""","style":{}}}"""))!,
    ];

    static readonly string Graph = """
        {"resume":{"id":"r1","title":"后端简历"},
         "groups":[{"kind":"work","items":[{"title":"虚构科技 · 后端实习"}]},{"kind":"project","items":[{"title":"校园二手平台"}]}],
         "graph":{"nodes":[{"key":"e1","kind":"experience","name":"虚构科技 · 后端开发实习生（2025）","status":"ok"},
                           {"key":"t1","kind":"technology","name":"Redis","status":"weak"},
                           {"key":"p1","kind":"point","name":"缓存穿透","status":"none"},
                           {"key":"p2","kind":"point","name":"分布式锁","status":"good","changed":"up"},
                           {"key":"x","kind":"unknown","name":"忽略"}],
                  "edges":[{"src":"e1","dst":"t1","kind":"ET"},{"src":"t1","dst":"p2","kind":"TP"},{"src":"e1","dst":"e1","kind":"EE"}]},
         "has_conclusions":true,"points":2,"weak_points":1,"weakest":{"key":"t1","name":"Redis（缓存）","experiences":1},
         "timeline":[{"kind":"mock","date":"2026-10-30","source":"模拟面试","source_id":"m1","tone":"up","name":"分布式锁","before":"差一点","after":"答到位","asked":4,"missed":1}],
         "today":"2026-10-31","entries":{"mock":{"count":2,"last_score":78.4}},"sources":{"resumes":1,"mocks":2,"interviews":0}}
        """;

    [Fact]
    public void GraphParsesAndPicksScreen()
    {
        var graph = new HomeGraph(J(Graph));
        Assert.Equal("r1", graph.ResumeId);
        Assert.Equal(["校园二手平台", "虚构科技 · 后端实习"], graph.Topics);
        Assert.Equal(4, graph.Nodes.Count);
        Assert.Equal(HomeGraph.Tone.Hot, graph.Nodes[1].Tone);
        Assert.Equal(HomeGraph.Tone.New, graph.Nodes[3].Tone);
        Assert.False(graph.Nodes[2].OnHome);
        Assert.Equal("虚构科技 · 后端开发实习生", graph.Nodes[0].Label);
        Assert.Equal(2, graph.Entry!.MockCount);

        var mocks = new HomeMockProgress(J("""{"items":[{"id":"m1","status":"completed","finished_at":"2026-10-30T08:00:00Z"},{"id":"m2","status":"abandoned"}]}"""));
        Assert.Equal(1, mocks.Count);
        // 第一场在新首页上线前就练完：不再提示“第一份报告好了”，有结论直接进有记忆首页
        Assert.Equal(HomeStage.Screen.Feedback, HomeStage.Pick(graph, mocks, reportSeen: false).Screen);
        var fresh = new HomeMockProgress(J("""{"items":[{"id":"m1","status":"completed","finished_at":"2026-11-15T08:00:00Z"}]}"""));
        Assert.Equal((HomeStage.Screen.FirstSteps, HomeStage.FirstSteps.Report), HomeStage.Pick(graph, fresh, reportSeen: false));
        Assert.Equal(HomeStage.Screen.Feedback, HomeStage.Pick(graph, fresh, reportSeen: true).Screen);
        Assert.Equal(HomeStage.Screen.NewUser, HomeStage.Pick(new HomeGraph(J("{}")), null, false).Screen);
    }

    [Fact]
    public void ProgressTextAndWhen()
    {
        var graph = new HomeGraph(J(Graph));
        var text = HomeProgressText.Of(graph.Timeline[0], graph.WeakPoints);
        Assert.Equal("分布式锁从差一点练到了答到位", text.Short);
        Assert.Equal("这一场问到 4 处。还有 1 个不牢。", text.Desc);
        Assert.Equal(("从差一点练到了", "答到位", ""), text.Lines[1]);
        Assert.Equal("今天", HomeProgressText.When("2026-10-31", "2026-10-31"));
        Assert.Equal("昨天", HomeProgressText.When("2026-10-30T10:00:00", "2026-10-31"));
        Assert.Equal("3 天前", HomeProgressText.When("2026-10-28", "2026-10-31"));
        Assert.Equal("10-01", HomeProgressText.When("2026-10-01", "2026-10-31"));
    }

    [Fact]
    public void LayoutIsDeterministicAndNormalized()
    {
        var graph = new HomeGraph(J(Graph));
        var first = HomeGraphLayout.Layout(graph.Nodes, graph.Edges);
        var second = HomeGraphLayout.Layout(graph.Nodes, graph.Edges);
        Assert.Equal(graph.Nodes.Count, first.Count);
        foreach (var (id, at) in first)
        {
            Assert.Equal(second[id], at);
            Assert.InRange(at.X, 0.06 - 1e-9, 0.94 + 1e-9);
            Assert.InRange(at.Y, 0.06 - 1e-9, 0.94 + 1e-9);
        }
    }

    [Fact]
    public void UpdatedLabelMatchesMac()
    {
        var resumes = Summaries();
        Assert.Equal("昨天", resumes[1].UpdatedLabel(Now, Shanghai));
        Assert.Equal("10-01", resumes[0].UpdatedLabel(Now, Shanghai));
        ResumeSummary At(string updated) => new("9", "", "", 1, "", updated, null);
        Assert.Equal("2025-03-04", At("2025-03-04T05:06:07.5").UpdatedLabel(Now, Shanghai));
        Assert.Equal("昨天", At("2026-10-30T15:59:59Z").UpdatedLabel(Now, Shanghai));
        Assert.Equal("—", At("not a date").UpdatedLabel(Now, Shanghai));
    }

    [Fact]
    public void AgentEventsMatchMac()
    {
        var completed = AgentEvent.Parse("event: run.completed\ndata: {\"run_id\":\"r1\",\"a\":1,\"a\":2}\n")!;
        Assert.True(completed.IsTerminal);
        Assert.True(JsonNode.DeepEquals(J("""{"run_id":"r1","a":1}"""), completed.Data));
        Assert.Null(AgentEvent.Parse("event: assistant.delta\r\ndata: {\"text\":\"hi\"}"));
        Assert.Null(AgentEvent.Parse("event: nope\ndata: {}"));
        var failed = AgentEvent.Parse("event: run.failed\ndata: [1,]")!;
        Assert.True(JsonNode.DeepEquals(J("[1]"), failed.Data));
        var phase = AgentEvent.Parse("data: {}\nevent: run.phase")!;
        Assert.False(phase.IsTerminal);
        Assert.True(JsonNode.DeepEquals(J("{}"), phase.Data));
        var nullData = AgentEvent.Parse("event: tool.started\ndata: null")!;
        Assert.Equal("tool.started", nullData.Type);
        Assert.Null(nullData.Data);
        Assert.Null(AgentEvent.Parse("event: tool.started\ndata: {bad"));
    }

    [Fact]
    public void AgentErrorsMatchMac()
    {
        Assert.Equal("登录已失效，请重新登录。", AgentErrors.Message(new ApiException(System.Net.HttpStatusCode.Unauthorized, "UNAUTHORIZED")));
        Assert.Equal("AI 助手暂时不可用，请稍后重试。", AgentErrors.Message(new ApiException(System.Net.HttpStatusCode.ServiceUnavailable, "X")));
        Assert.Equal("上一条回复还在生成，请稍候。", AgentErrors.Message(new ApiException(System.Net.HttpStatusCode.Conflict, "AGENT_RUN_IN_PROGRESS")));
        Assert.Equal("操作没有完成（BAD）。", AgentErrors.Message(new ApiException(System.Net.HttpStatusCode.BadRequest, "BAD")));
        Assert.Equal("连接中断，回复结果尚未确认。可以刷新对话查看。", AgentErrors.Message(new InvalidDataException()));
    }
}
