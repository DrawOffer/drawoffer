using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Home;
using DrawOffer.Core.Models;
using Xunit;

namespace DrawOffer.Core.Tests;

/// <summary>
/// 首页场景、星图摆放、首页卡片与 AI 事件。Mac 没有这些规则的单元测试；期望值来自用同样虚构数据
/// 运行 Mac `DrawOfferCore`（Asia/Shanghai 时区）打印的结果，逐字段比较（Fixtures/home-scenes.mac.txt）。
/// </summary>
public sealed class HomeTests
{
    static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
    static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-10-31T02:00:00Z", CultureInfo.InvariantCulture);

    static JsonNode J(string source) => JsonNode.Parse(source)!;
    static string F(double value) => value.ToString("F6", CultureInfo.InvariantCulture);
    static string Lower<T>(T value) where T : Enum => value.ToString().ToLowerInvariant();

    static string Run(HomeAction action) => action switch
    {
        HomeAction.Mock mock => mock.Focus is { } f ? $"mock(Optional(Gold.PracticeFocus(kind: \"{f.Kind}\", ref: \"{f.Ref}\", label: \"{f.Label}\")))" : "mock(nil)",
        HomeAction.Guide guide => $"guide([{string.Join(", ", guide.Ids.Select(x => $"\"{x}\""))}])",
        HomeAction.Chat chat => $"chat(\"{chat.Prompt}\")",
        HomeAction.Suggest suggest => $"suggest(\"{suggest.Text}\")",
        _ => "?",
    };

    /// <summary>与对照程序 `dump` 相同的格式。</summary>
    static IEnumerable<string> Dump(HomeScene s)
    {
        yield return $"key={s.Key} eyebrow={s.Eyebrow} tone={Lower(s.EyebrowTone)} title={s.Title}";
        yield return $"sub={s.Sub} listTitle={s.ListTitle} mapTitle={s.MapTitle} mapNote={s.MapNote}";
        yield return "list=" + string.Join(";", s.List.Select(x => $"{x.Id}|{Lower(x.Sym)}|{x.Title}|{x.Right ?? "-"}|{x.Sub}|{(x.Badge?.ToString() ?? "-")}"));
        yield return "nodes=" + string.Join(";", s.Nodes.Select(x =>
            $"{x.Id}|{Lower(x.Sym)}|{x.Label}|{x.Sub ?? "-"}|{(x.SubTone is { } t ? Lower(t) : "-")}|{x.Level?.ToString() ?? "-"}|{x.Badge?.ToString() ?? "-"}|{x.Group}|{x.Parent ?? "-"}"));
        yield return "edges=" + string.Join(";", s.Edges.Select(x => $"{x.From}>{x.To}{(x.Prereq ? "!" : "")}"));
        yield return "planets=" + string.Join(";", s.Planets.Select(x => $"{x.Id}|{x.Label}|{x.Sub}|{string.Join(",", x.Links)}"));
        yield return $"region={(s.Region is { } r ? r.Title + ":" + string.Join(",", r.Members) : "-")}";
        yield return "marks=" + string.Join(";", s.Marks.Select(x => $"{x.Id}|{x.Label}|{x.Sub ?? "-"}|{Lower(x.Tone)}|{(x.Future ? "true" : "false")}|{F(SwiftCompat.Epoch(x.At))}"));
        yield return $"suggestion={s.Suggestion} disclose={string.Join(",", s.Disclose)}";
        yield return $"action={(s.Action is { } a ? a.Label + "|" + Run(a.Run) : "-")}";
        var layout = HomeLayouts.Layout(s);
        yield return "layout=" + string.Join(";", layout.At.Keys.OrderBy(x => x, SwiftCompat.StringOrder).Select(k => $"{k}@{F(layout.At[k].X)},{F(layout.At[k].Y)},{Lower(layout.At[k].Side)}"));
        yield return $"box={(layout.Region is { } b ? $"{F(b.Cx)},{F(b.Cy)},{F(b.Rx)},{F(b.Ry)},{F(b.TitleY)}" : "-")}";
        yield return "placed=" + string.Join(";", HomeLayouts.PlaceMarks(s.Marks, Now).Select(x => $"{x.mark.Id}@{F(x.x)}"));
    }

    static HomeInput Input(MemoryHome? home, IReadOnlyList<HomeResume> resumes, IReadOnlyList<HomeDataset> datasets, IReadOnlyList<HomeSession> sessions, string[] directions, string? role) =>
        new(Now, home, resumes, datasets, sessions, directions, role) { Zone = Shanghai };

    static readonly HomeResume[] Resumes = [new("1", "后端简历", "2026-10-30T01:00:00")];

    static List<string> Actual()
    {
        var lines = new List<string>();
        var home = new MemoryHome(J("""
{"enabled":true,"target":{"computing":true},
 "nodes":[
   {"key":"t:redis:persist","name":"Redis 持久化","grade":null,"level":2,"last_date":"2026-10-20","asks":[{"date":"2026-10-20","kind":"mock","source_id":"m1"}]},
   {"key":"t:redis:cluster","name":"Redis 集群","grade":"good","grade_label":"答得好","level":3,"best_level":4,"last_date":"2026-10-22","asks":[{"date":"2026-10-22","kind":"real","source_id":"r1","company":"虚构云","stage":"一面"}]},
   {"key":"t:mysql:index","name":"MySQL 索引","grade":null,"level":1,"asks":[{"date":"2026-08-01","kind":"mock","source_id":"m0"}]}
 ],
 "issues":[{"key":"i1","kind":"knowledge_gap","statement":"持久化细节讲不清","node":"t:redis:persist","name":"Redis 持久化","held":"L2","cause":"shallow","practice":{"kind":"topic","ref":"t:redis:persist","label":"Redis 持久化"}}],
 "links":[{"key":"t:redis","name":"Redis"},{"key":"t:redis:store","name":"Redis 存储","parent":"t:redis"},{"key":"t:redis:persist","name":"Redis 持久化","parent":"t:redis:store"},{"key":"t:redis:cluster","name":"Redis 集群","parent":"t:redis"},{"key":"t:mysql","name":"MySQL"},{"key":"t:mysql:index","name":"MySQL 索引","parent":"t:mysql"}],
 "edges":[{"src":"t:redis:cluster","dst":"t:redis:persist"}],
 "neighbors":{"t:redis:persist":["t:redis:cluster","t:mysql:index"]},
 "resume_technologies":[{"key":"t:redis","name":"Redis","topics":["t:redis:persist"]},{"key":"t:kafka","name":"Kafka","topics":["t:kafka:ack"]}],
 "experiences":[],"competencies":[{"key":"cmp:comm","name":"沟通","coverage":0.4}],
 "unasked":["t:kafka:ack"],"unasked_from":{"kind":"application","company":"虚构云","title":"后端开发工程师（存储方向，校招）"}}
"""));
        var sessions = new[] { HomeSession.FromJson(J("""{"id":7,"status":"scheduled","start_at":"2026-11-02T06:00:00Z","company_name":"虚构云","stage_label":"二面"}"""), Shanghai)! };
        lines.Add("== weak");
        lines.AddRange(Dump(HomeScenes.Pick(Input(home, Resumes, [], sessions, ["rd"], null))));
        lines.Add("== start");
        lines.AddRange(Dump(HomeScenes.Pick(Input(null, [], [], [], ["product"], null))));
        lines.Add("== materials");
        var docs = new[]
        {
            new HomeDataset(J("""{"id":11,"file_name":"实习证明.pdf","created_at":"2026-10-29T03:00:00","upload_status":"succeeded","parse_status":"succeeded"}""")),
            new HomeDataset(J("""{"id":12,"file_name":"项目总结.docx","created_at":"2026-10-30T15:30:00","upload_status":"succeeded","parse_status":"succeeded"}""")),
            new HomeDataset(J("""{"id":13,"file_name":".hidden","created_at":"2026-10-30T16:30:00","upload_status":"succeeded","parse_status":"succeeded"}""")),
        };
        lines.AddRange(Dump(HomeScenes.Pick(Input(null, [], docs, [], [], "数据分析"))));
        lines.Add("== forming");
        var forming = new MemoryHome(J("""
{"enabled":true,"nodes":[{"key":"t:a:x","name":"A X","grade":"ok","level":3,"last_date":"2026-10-25","asks":[{"date":"2026-10-25","kind":"mock","source_id":"m9"}]},{"key":"t:a:y","name":"A Y","level":2,"asks":[{"date":"2026-10-26","kind":"mock","source_id":"m9"}]}],
 "issues":[{"key":"d1","kind":"review_due","node":"t:a:x","name":"A X","date":"2026-09-01","statement":""}],
 "links":[{"key":"t:a","name":"A"},{"key":"t:a:x","name":"A X","parent":"t:a"},{"key":"t:a:y","name":"A Y","parent":"t:a"},{"key":"t:b","name":"Bee"},{"key":"t:b:z","name":"Bee Zed","parent":"t:b"}],
 "resume_technologies":[{"key":"t:b","name":"Bee","topics":["t:b:z"]}],"experiences":[{"key":"e1","title":"实习","told":true,"gaps":[]}]}
"""));
        lines.AddRange(Dump(HomeScenes.Pick(Input(forming, Resumes, [], [], [], null))));
        lines.Add("== experience");
        var experience = new MemoryHome(J("""
{"enabled":true,"nodes":[],"issues":[{"key":"u1","kind":"unclear_telling","statement":"结果没量化","name":"推荐系统","experience":"e1","element":"结果","facet":"result"}],
 "experiences":[{"key":"e1","title":"推荐系统","told":false,"gaps":[{"facet":"result","element":"结果","issue":"u1"},{"facet":"impact","element":"影响","issue":"u2"}]},{"key":"e2","title":"校园大使","told":true,"gaps":[]}]}
"""));
        lines.AddRange(Dump(HomeScenes.Pick(Input(experience, Resumes, [], [], ["product"], null))));
        lines.Add("== return");
        var back = new MemoryHome(J("""
{"enabled":true,"nodes":[{"key":"t:a:x","name":"A X","grade":"ok","level":3,"best_level":4,"last_date":"2026-10-01","asks":[{"date":"2026-10-01","kind":"mock","source_id":"m1"}]}],
 "issues":[{"key":"d1","kind":"review_due","node":"t:a:x","name":"A X","date":"2026-10-01","statement":"","practice":{"kind":"topic","ref":"t:a:x","label":"A X"}}],
 "links":[{"key":"t:a","name":"A"},{"key":"t:a:x","name":"A X","parent":"t:a"}]}
"""));
        lines.AddRange(Dump(HomeScenes.Pick(Input(back, Resumes, [], [], [], null))));
        lines.Add("== resume");
        var resume = new MemoryHome(J("""
{"enabled":true,"nodes":[],"issues":[],"links":[{"key":"t:go","name":"Go"},{"key":"t:go:gc","name":"Go GC","parent":"t:go"},{"key":"t:go:ch","name":"Go channel","parent":"t:go"}],
 "resume_technologies":[{"key":"t:go","name":"Go","topics":["t:go:gc","t:go:ch"]},{"key":"t:k8s","name":"K8s","topics":["t:k8s:pod"]}]}
"""));
        lines.AddRange(Dump(HomeScenes.Pick(Input(resume, Resumes, [], [], ["rd"], null))));
        return lines;
    }

    [Fact]
    public void ScenesAndLayoutMatchMacOutputLineByLine()
    {
        using var stream = typeof(HomeTests).Assembly.GetManifestResourceStream("Fixture.home-scenes.mac.txt")!;
        var expected = new StreamReader(stream).ReadToEnd().Split('\n').Where(x => x.Length > 0).ToList();
        var actual = Actual();
        Assert.Equal(expected.Count, actual.Count);
        for (var i = 0; i < expected.Count; i++) Assert.Equal(expected[i], actual[i]);
    }

    [Fact]
    public void HelpersMatchMac()
    {
        Assert.Equal("0.382000", F(HomeLayouts.Hash("t:redis")));
        Assert.Equal("0.854000", F(HomeLayouts.Hash("资料")));
        Assert.Equal("683.884978", F(HomeCanvas.HorizonY(300)));
        Assert.Equal("79.200000", F(HomeLayouts.TextWidth("Redis 持久化", 12)));
        // 2 月 30 日顺延到 3 月 2 日；13 月顺延到次年 1 月；读不出时为 distantPast。
        Assert.Equal("1772424000.000000", F(SwiftCompat.Epoch(HomeScenes.DateOf("2026-02-30"))));
        Assert.Equal("1798776000.000000", F(SwiftCompat.Epoch(HomeScenes.DateOf("2026-13-01"))));
        Assert.Equal(SwiftCompat.DistantPast, HomeScenes.DateOf("x"));
        Assert.Equal(["a.b", ".md", "noext"], new[] { "a.b.c", ".md", "noext" }.Select(HomeScenes.Stem));
    }

    static readonly string Preview = """{"identity":{"node_id":"node_identity","name":{"value":"林晓"},"headline":{"value":"后端开发 · 2026 届"},"contacts":[{"value":"13912345678"},{"value":"lin@fixture.dev"}]},"sections":[]}""";

    static List<ResumeSummary> Summaries() =>
    [
        ResumeSummary.From(J("""{"id":"2","title":"旧","source_type":"template","lock_version":1,"created_at":"2026-10-01T00:00:00","updated_at":"2026-10-01T00:00:00","preview":null}"""))!,
        ResumeSummary.From(J("""{"id":"3","title":"新","source_type":"template","lock_version":1,"created_at":"2026-10-01T00:00:00","updated_at":"2026-10-30T08:00:00","preview":{"data":""" + Preview + ""","style":{}}}"""))!,
    ];

    static readonly JsonNode?[] Applications =
    [
        J("""{"id":"a1","status":"active","offer_status":"none","stage_state":"awaiting_result","company_name_snapshot":"虚构甲","current_stage_label":"一面","current_stage":{"stage_type":"interview"},"applied_at":"2026-10-28T00:00:00Z"}"""),
        J("""{"id":"a2","status":"active","offer_status":"none","phase":"pending","company_name_snapshot":"虚构乙","applied_at":"2026-10-01T00:00:00Z"}"""),
    ];

    static string CardName(HomeDashboard.Card card)
    {
        var name = card.GetType().Name;
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    [Fact]
    public void DashboardMatchesMac()
    {
        var sessions = new[] { J("""{"id":1,"status":"scheduled","start_at":"2026-11-03T02:00:00Z","stage_label":"笔试","company_name":"虚构丙","end_at":"2026-11-02T10:00:00Z"}""") };
        var deadline = HomeDashboard.Build(Now, Summaries(), sessions, Applications, Shanghai);
        Assert.Equal(HomeDashboard.DashboardVariant.Deadline, deadline.Variant);
        Assert.Equal(["deadline", "resumeRecent", "pipeline"], deadline.Cards.Select(CardName));
        Assert.Equal("虚构丙的笔试 2 天后截止。", deadline.Copy.Subtitle);
        Assert.Equal(0, deadline.TodayCount);
        Assert.Equal("3", Assert.IsType<HomeDashboard.Card.ResumeRecent>(deadline.Cards[1]).Resume.Id);
        Assert.Equal("虚构甲一面结果待出", Assert.IsType<HomeDashboard.Card.Pipeline>(deadline.Cards[2]).Hint);

        var idle = HomeDashboard.Build(Now, Summaries(), [], Applications, Shanghai);
        Assert.Equal(["week", "resumeRecent", "jobs"], idle.Cards.Select(CardName));
        Assert.Equal("适合补一段项目经历，或者看看新岗位。", idle.Copy.Subtitle);
        Assert.Equal(["week", "resumeRecent", "jobs"], HomeDashboard.Build(Now, Summaries(), [], [], Shanghai).Cards.Select(CardName));
        Assert.Equal(["firstResume", "target", "plugin"], HomeDashboard.Build(Now, [], [], [], Shanghai).Cards.Select(CardName));

        Assert.Equal((1, 0, 1, 0), HomeDashboard.PipelineColumns(Applications));
        Assert.Equal("1792944000.000000", F(SwiftCompat.Epoch(HomeDashboard.StartOfWeek(Now, Shanghai))));
        Assert.Equal("1792944000.000000", F(SwiftCompat.Epoch(HomeDashboard.StartOfWeek(DateTimeOffset.Parse("2026-11-01T15:00:00Z", CultureInfo.InvariantCulture), Shanghai))));
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
