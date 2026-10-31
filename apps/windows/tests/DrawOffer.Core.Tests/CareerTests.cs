using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;

/// <summary>Mac `CareerTests.swift` 的逐条移植。</summary>
public class CareerTests {
    private static CareerApplication Application(string json)=>new(JsonNode.Parse(json)!);

    [Fact] public void careerChannelsHaveNarrowRouteBoundary() {
        Assert.True(CareerRequest.Allowed("/api/job-applications/12/stages","POST"));
        Assert.True(CareerRequest.Allowed("/api/interview-sessions/12/answer-plan","PUT"));
        foreach(var path in new[]{"/api/account/avatar","/api/job-applications/12/reviews","/api/job-applications//12","/api/job-applications/12/","/api/job-applications/１２","/api/job-applications?scope=all"})
            Assert.False(CareerRequest.Allowed(path,"GET"),path);
        Assert.False(CareerRequest.Allowed("/api/resumes/1/semantic-classification","POST"));
        foreach(var (path,method) in new[]{("/api/resumes/1","DELETE"),("/api/resumes/1/copy","POST"),("/api/resumes/1/share","PATCH"),
                ("/api/resume-imports/3","DELETE"),("/api/resumes/1/apply-template","POST"),("/api/resumes/1/assets","POST"),
                ("/api/resumes/1/assets/a.png","DELETE"),("/api/account/profile","GET"),("/api/account/user-profile","PUT"),
                ("/api/agent/sessions","POST"),("/api/agent/proposals/abc/confirm","POST"),("/api/job-descriptions/2/match","GET")})
            Assert.True(CareerRequest.Allowed(path,method),$"{method} {path}");
        foreach(var (path,method) in new[]{("/api/resumes/1/assets","GET"),("/api/resumes/1/apply-template","GET"),("/api/account/deletion","POST"),("/api/admin/agent-operations","GET"),
                ("/api/agent/sessions/1/messages","POST"),("/api/resumes/abc","GET")})
            Assert.False(CareerRequest.Allowed(path,method),$"{method} {path}");
        Assert.True(AgentRequest.Streams("/api/agent/sessions/1/messages","POST"));
    }

    [Fact] public void careerProjectionKeepsPendingNullAndDynamicInterviewColumns() {
        var pending=Application("""{"id":"1","phase":"","current_stage":null,"current_stage_type":"screening","applied_at":null}""");
        Assert.Equal("pending",pending.Stage);
        var second=Application("""{"id":"2","phase":"active","current_stage":{"stage_type":"interview","stage_label":"技术二面"},"current_round_no":2}""");
        var first=Application("""{"id":"3","phase":"active","current_stage":{"stage_type":"interview","stage_label":"技术一面"},"current_round_no":1}""");
        Assert.Equal(new[]{"interview:技术一面","interview:技术二面"},CareerStage.Columns([second,first]).Where(x=>x.StartsWith("interview:",StringComparison.Ordinal)));
        Assert.False(CareerStage.CanAdvance(first,"screening"));
        Assert.True(CareerStage.CanAdvance(first,"offer"));
        Assert.Equal(new[]{"interview","offer"},CareerStage.NextStages(first));
        var ai=Application("""{"id":"5","phase":"active","current_stage_type":"ai_interview","current_stage_label":"AI 面试"}""");
        Assert.Equal("interview:AI 面试",ai.Column);
        Assert.DoesNotContain("ai_interview",CareerStage.Columns([ai]));
        Assert.False(CareerStage.CanAdvance(first,ai.Column,"ai_interview"));
        var ended=Application("""{"id":"4","lifecycle_status":"terminated","current_stage_type":"interview"}""");
        Assert.Equal("ended",ended.Stage);
        Assert.False(CareerStage.CanAdvance(ended,"offer"));
    }

    [Fact] public void careerOrderingUsesUpcomingScheduleAndStableNumericIDs() {
        var a=Application("""{"id":"10","phase":"active","current_stage_type":"interview","created_at":"2030-01-01T00:00:00Z","next_session_start_at":"2030-01-04T00:00:00Z"}""");
        var b=Application("""{"id":"2","phase":"active","current_stage_type":"interview","created_at":"2030-01-01T00:00:00Z","next_session_start_at":"2030-01-05T00:00:00Z"}""");
        Assert.Equal(new[]{"10","2"},CareerStage.Sorted([b,a],false).Select(x=>x.Id));
        Assert.Equal(new[]{"2","10"},CareerStage.Sorted([a,b],true).Select(x=>x.Id));
    }

    [Fact] public void careerCompletedHistoryOnlyUsesCurrentStageAndNewestNonCancelledSession() {
        var raw=Application("""{"id":"1","phase":"active","current_stage":{"id":"8","stage_type":"interview"}}""");
        var sessions=JsonNode.Parse("""[{"application_id":"1","application_stage_id":"7","status":"completed","start_at":"2030-01-05T00:00:00Z"},{"application_id":"1","application_stage_id":"8","status":"completed","start_at":"2030-01-04T00:00:00Z"},{"application_id":"1","application_stage_id":"8","status":"cancelled","start_at":"2030-01-06T00:00:00Z"}]""").Items();
        Assert.Equal(CareerApplication.Date("2030-01-04T00:00:00Z"),raw.IncludingSessions(sessions).CompletedSchedule);
        Assert.Equal("已完成",raw.IncludingSessions(sessions).StatusLabel);
    }

    [Fact] public void companyLogoOnlyAcceptsOwnedVersionedRelativeResource() {
        var revision=new string('a',64);
        var own=Application("{\"company_logo_url\":\"/api/job-descriptions/2/logo?v="+revision+"\"}");
        Assert.Equal("/api/job-descriptions/2/logo",own.LogoRequest?.Path);
        Assert.Equal(revision,own.LogoRequest?.Revision);
        foreach(var value in new[]{"https://example.com/api/job-descriptions/2/logo?v="+revision,"//example.com/logo","/api/job-descriptions/2/logo?v=short","/api/resumes/2?v="+revision})
            Assert.Null(new CareerApplication(new JsonObject{["company_logo_url"]=value}).LogoRequest);
    }

    [Fact] public void v4NextActionSeparatesOralFormalAndTerminalOffer() {
        var oc=Application("""{"id":"1","current_stage_type":"offer","offer_status":"none","status":"active"}""");
        Assert.Equal("offer",new CareerFlow(oc).Kind);
        var formal=Application("""{"id":"2","current_stage_type":"offer","offer_status":"received","status":"active"}""");
        Assert.Equal("accept",new CareerFlow(formal).Kind);
        foreach(var decision in new[]{"accepted","declined"}){
            var ended=new CareerApplication(new JsonObject{["status"]="closed",["current_stage_type"]="offer",["offer_status"]=decision});
            Assert.Equal("ended",ended.Stage);
            Assert.False(ended.Movable);
            Assert.Equal("history",new CareerFlow(ended).Kind);
        }
        var waiting=Application("""{"current_stage_type":"interview","stage_state":"awaiting_schedule"}""");
        Assert.Equal("schedule-current",new CareerFlow(waiting).Kind);
        var scheduled=Application("""{"current_stage_type":"interview","stage_state":"scheduled"}""");
        Assert.Equal("records",new CareerFlow(scheduled).Kind);
        var done=new CareerApplication(scheduled.Raw,DateTimeOffset.Now);
        Assert.Equal("stage",new CareerFlow(done).Kind);
        foreach(var command in new[]{"close","archive","restore"}){
            Assert.True(CareerRequest.Allowed("/api/job-applications/12/"+command,"POST"));
            Assert.False(CareerRequest.Allowed("/api/job-applications/12/"+command,"PUT"));
        }
    }

    [Fact] public void v4NotesPreserveUnrelatedDataAndReplaceOnlySelectedFields() {
        var original="个人备注\n投递渠道：官网\n未识别字段：保留";
        var merged=CareerNotes.Merge(new(){["投递渠道"]="内推",["回复截止"]="2030-01-02"},original);
        Assert.Contains("个人备注",merged);
        Assert.Contains("未识别字段：保留",merged);
        Assert.DoesNotContain("官网",merged);
        Assert.Equal("内推",CareerNotes.Value("投递渠道",merged));
    }

    [Fact] public void v4ProgressPreservesMultipleRoundsAndOralBeforeFormalWithoutInventingStages() {
        var item=Application("""{"id":"1","status":"active","current_stage_type":"offer","offer_status":"received","current_stage":{"id":"5","stage_type":"offer","stage_label":"OC"},"notes":"收到日期：2030-10-24T09:00:00Z","stages":[{"id":"2","stage_type":"interview","stage_label":"一面"},{"id":"3","stage_type":"interview","stage_label":"二面"},{"id":"4","stage_type":"interview","stage_label":"HR 面"},{"id":"5","stage_type":"offer","stage_label":"OC"}]}""");
        var steps=CareerProgress.Steps(item);
        Assert.Equal(new[]{"已投递","一面","二面","HR 面","OC","Offer"},steps.Select(x=>x.Label));
        Assert.Equal("current",steps.Last().State);
        Assert.Equal("2030-10-24T09:00:00Z",steps.Last().Date);
        Assert.DoesNotContain(steps,x=>x.Label.Contains("笔试"));
    }
}
