using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;

/// <summary>Mac `CareerDetailTests.swift` 的逐条移植。</summary>
public class CareerDetailTests {
    private static JsonNode Json(string source)=>JsonNode.Parse(source)!;
    private static readonly TimeZoneInfo Shanghai=TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
    private static readonly DateTimeOffset Now=DateTimeOffset.Parse("2030-10-06T02:00:00Z");

    private const string ScheduledApplication = """
{"id":"7","status":"active","lifecycle_status":"active","phase":"applied","archived_at":null,"stage_state":"scheduled",
 "current_stage_type":"interview","current_stage_label":"一面 · 技术基础","current_round_no":1,"offer_status":"none",
 "applied_at":"2030-09-28T02:00:00Z","applied_channel":"同事内推","resume_title_snapshot":"Backend_v3.pdf","created_at":"2030-09-27T02:00:00Z","updated_at":"2030-10-05T02:00:00Z",
 "current_stage":{"id":"13","stage_type":"interview","stage_label":"一面 · 技术基础"},
 "stages":[
  {"id":"11","sequence_no":1,"stage_type":"screening","stage_label":"筛选中","stage_result":"passed","entered_at":"2030-09-28T02:00:00Z","completed_at":"2030-09-30T02:00:00Z"},
  {"id":"12","sequence_no":2,"stage_type":"written_test","stage_label":"技术笔试","stage_result":"passed","entered_at":"2030-09-30T02:00:00Z","completed_at":"2030-10-05T02:00:00Z"},
  {"id":"13","sequence_no":3,"stage_type":"interview","stage_label":"一面 · 技术基础","stage_result":"pending","current_marker":1,"entered_at":"2030-10-05T02:00:00Z"}]}
""";
    private const string Sessions = """
[{"id":"31","application_id":"7","application_stage_id":"13","status":"scheduled","stage_type":"interview","stage_label":"一面 · 技术基础","round_no":1,
  "start_at":"2030-10-08T06:00:00Z","end_at":"2030-10-08T07:00:00Z","mode":"video","interviewer_name":"李老师","schedule_kind":"fixed_slot"},
 {"id":"30","application_id":"7","application_stage_id":"12","status":"completed","stage_type":"other","stage_label":"技术笔试",
  "start_at":"2030-10-04T12:10:00Z","end_at":"2030-10-04T13:25:00Z","mode":"other","schedule_kind":"fixed_slot"}]
""";

    [Fact] public void scheduledInterviewProjectsDateTileAndRecordAction() {
        var model=new CareerDetailModel(Json(ScheduledApplication),Json(Sessions).Items(),Now,Shanghai);
        Assert.Equal(new[]{"已投递","筛选","技术笔试","一面 · 技术基础","下一阶段"},model.Steps.Select(x=>x.Label));
        Assert.Equal(new[]{CareerDetailStepState.Done,CareerDetailStepState.Done,CareerDetailStepState.Done,CareerDetailStepState.Current,CareerDetailStepState.Next},model.Steps.Select(x=>x.State));
        Assert.Equal("09.30 · 已通过",model.Steps[1].Meta);
        Assert.Equal("10.08",model.Steps[3].Meta);
        var tile=Assert.IsType<CareerDetailTile.Date>(model.Next.Tile);
        Assert.True(tile.Head=="10月 · 周二"&&tile.Day=="8"&&tile.Foot=="14:00",$"{tile.Head}|{tile.Day}|{tile.Foot}");
        Assert.Equal(new[]{"一面 · 技术基础","已安排","还有 2 天"},model.Next.Chips.Select(x=>x.Label));
        Assert.Equal("10.08 14:00–15:00 · 视频面试 · 面试官 李老师",model.Next.Detail);
        Assert.Equal(CareerDetailAction.RecordReview,model.Next.Primary?.Action);
        Assert.Equal(new[]{CareerDetailAction.Reschedule,CareerDetailAction.CancelSession},model.Next.Secondary.Select(x=>x.Action));
        Assert.Equal("31",model.CurrentSession?.Text("id"));
        Assert.Equal(new[]{"一面 · 技术基础","技术笔试","简历筛选","提交投递"},model.History.Select(x=>x.Title));
        Assert.True(model.History[0].Highlight==CareerTone.Blue&&model.History[0].SessionId=="31");
        Assert.Equal("10.04 20:10–21:25 完成",model.History[1].Detail);
        Assert.Equal("同事内推 · Backend_v3.pdf",model.History[3].Detail);
        Assert.Equal(new[]{"09.28","同事内推","Backend_v3.pdf"},model.DeliveryRows.Select(x=>x.Value));
        Assert.Equal("已投递 8 天",model.HeaderMeta);
    }

    [Fact] public void elapsedSessionWaitsForResultWithoutManualCompletion() {
        var later=DateTimeOffset.Parse("2030-10-09T02:00:00Z");
        var model=new CareerDetailModel(Json(ScheduledApplication),Json(Sessions).Items(),later,Shanghai);
        Assert.Equal("一面 · 技术基础已结束，等待面试结果",model.Next.Title);
        Assert.Equal(CareerDetailAction.Advance,model.Next.Primary?.Action);
        Assert.Equal("10.08 · 已面完",model.Steps[3].Meta);
        Assert.Equal(new CareerChip("等待结果",CareerTone.Orange),model.History[0].Chip);
        Assert.Equal("31",model.LatestRecorded?.Text("id"));
    }

    [Fact] public void pendingVerbalAndReceivedOfferStates() {
        var pending=new CareerDetailModel(Json("""{"id":"1","status":"active","lifecycle_status":"active","phase":"pending","archived_at":null,"current_stage_type":"screening","current_stage_label":"待投递","offer_status":"none","created_at":"2030-10-01T02:00:00Z","stages":[]}"""),[],Now,Shanghai);
        Assert.True(pending.Pending&&pending.Steps.Count==5&&pending.Next.Primary?.Action==CareerDetailAction.RecordApplied);
        Assert.Equal("未投递",pending.DeliveryRows[0].Value);

        var oc=Json("""{"id":"2","status":"active","lifecycle_status":"active","phase":"applied","archived_at":null,"current_stage_type":"offer","current_stage_label":"OC","offer_status":"none","applied_at":"2030-09-01T02:00:00Z","oc_communicated_at":"2030-10-02T02:00:00Z","oc_salary_text":"30K × 15","current_stage":{"id":"5","stage_type":"oc","stage_label":"OC"},"stages":[{"id":"5","sequence_no":1,"stage_type":"oc","stage_label":"OC","current_marker":1,"entered_at":"2030-10-02T02:00:00Z"}]}""");
        var verbal=new CareerDetailModel(oc,[],Now,Shanghai);
        Assert.True(verbal.VerbalOffer&&verbal.Next.Primary?.Action==CareerDetailAction.RecordOffer);
        Assert.Equal("口头意向",verbal.OfferCard?.Title);
        Assert.True(verbal.History[0].Title=="OC · 口头意向"&&verbal.History[0].Detail=="口头薪酬 30K × 15");

        var received=Json("""{"id":"3","status":"active","lifecycle_status":"active","phase":"applied","archived_at":null,"current_stage_type":"offer","current_stage_label":"Offer","offer_status":"received","offer_reply_due_on":"2030-10-09","offer_received_on":"2030-10-03","offer_salary":"35000","offer_salary_period":"month","offer_base_location":"北京","applied_at":"2030-09-01T02:00:00Z","current_stage":{"id":"6","stage_type":"offer","stage_label":"Offer"},"stages":[{"id":"6","sequence_no":1,"stage_type":"offer","stage_label":"Offer","current_marker":1,"entered_at":"2030-10-03T02:00:00Z"}]}""");
        var decision=new CareerDetailModel(received,[],Now,Shanghai);
        Assert.Equal(new CareerChip("还有 3 天回复",CareerTone.Orange),decision.Next.Chips.Last());
        Assert.Equal("北京 · 35000 / 月 · 回复截止 10.09",decision.Next.Detail);
        Assert.Equal("2030年10月9日",decision.OfferCard?.Rows.FirstOrDefault(x=>x.Label=="回复截止")?.Value);
        Assert.True(decision.Steps.Last().State==CareerDetailStepState.Offer&&decision.Steps.Last().Meta=="10.03 · 已收到");
    }

    [Fact] public void rejectedApplicationEndsWithFailedStep() {
        var source="""{"id":"4","status":"active","lifecycle_status":"terminated","termination_reason":"company_rejected","terminated_at":"2030-10-05T02:00:00Z","archived_at":null,"current_stage_type":"interview","current_stage_label":"二面","offer_status":"none","applied_at":"2030-09-01T02:00:00Z","stages":[{"id":"8","sequence_no":1,"stage_type":"interview","stage_label":"二面","entered_at":"2030-09-20T02:00:00Z"}]}""";
        var model=new CareerDetailModel(Json(source),[],Now,Shanghai);
        Assert.True(model.Ended&&model.Steps.Last().State==CareerDetailStepState.Failed);
        Assert.True(model.Next.Title=="流程已结束：二面未通过");
        Assert.True(model.Next.Primary?.Action==CareerDetailAction.ViewReview&&model.Next.Primary?.Dark==false);
    }

    [Fact] public void reviewReportProjectionsMatchWeb() {
        Assert.Equal(81,CareerReview.Score100(Json("""{"schema_version":2,"total_score":81.4}""")));
        Assert.Equal(73,CareerReview.Score100(Json("""{"overall_score":7.26}""")));
        Assert.Equal(new CareerChip("良好",CareerTone.Green),CareerReview.Grade(81));
        Assert.Equal(new CareerChip("存在风险",CareerTone.Orange),CareerReview.Verdict("at_risk"));
        Assert.Equal("记录已修改，待重新生成",CareerReview.StatusText(Json("""{"review_stale":true}""")));
        Assert.Equal("复盘 88",CareerReview.StatusText(Json("""{"review_report":{"schema_version":2,"total_score":88}}""")));
        var points=CareerReview.RadarPoints([5,null,5,5,5],78,110);
        Assert.True(Math.Abs(points[0].X-110)<0.001&&Math.Abs(points[0].Y-32)<0.001);
        Assert.True(Math.Abs(points[1].X-110)<0.001&&Math.Abs(points[1].Y-110)<0.001);
        Assert.Equal("没有岗位要求，不评这一项",CareerReview.DimensionNote(Json("""{"key":"job_fit","assessed":false}""")));
        Assert.Equal("权重 20% · 先结论",CareerReview.DimensionNote(Json("""{"key":"structure","assessed":true,"weight":0.2,"comment":"先结论"}""")));
        var notes=CareerReview.Notes(Json("""{"review_question_notes":[{"question_key":"a"},{"question_key":"gone"}]}"""),Json("""{"questions":[{"key":"a"}]}"""));
        Assert.True(notes.ByKey.ContainsKey("a"));
        Assert.Equal(new[]{"gone"},notes.Unmatched.Select(x=>x.Text("question_key")));
    }

    [Fact] public void transcriptAndQuestionParsingMatchesWeb() {
        var lines=CareerTranscript.Lines("面试官：先自我介绍\n我: 我负责订单\n  \n普通段落");
        Assert.Equal(new CareerTranscript.Line[]{new("面试官","先自我介绍"),new("我","我负责订单"),new(null,"普通段落")},lines);
        Assert.True(lines[1].IsMe&&!lines[0].IsMe);
        // Same rule as Web: the marker must be followed by whitespace.
        Assert.Equal(new[]{"第一题","第二题","第三题"},CareerTranscript.Questions("1. 第一题\n2、 第二题\n- 第三题\n3.没有空格\n4、紧跟文字\n普通"));
        Assert.Equal(2,CareerSessions.QuestionCount("1. a\n2) b\n说明"));
        Assert.Equal("录音里没有识别到有效的语音。",CareerTranscript.TranscriptionError("INTERVIEW_TRANSCRIPTION_EMPTY"));
    }

    [Fact] public void stageDetailRoutesAreNarrow() {
        foreach(var (path,method) in new[]{("/api/interview-sessions/3/review:generate","POST"),("/api/interview-sessions/3/review-notes","PUT"),
                ("/api/interview-sessions/3/review-notes/9","DELETE"),("/api/interview-sessions/3/transcriptions/4:retry","POST"),
                ("/api/interview-sessions/3/transcriptions/4:apply","POST"),("/api/interview-sessions/3/written-questions:extract","POST"),
                ("/api/interview-sessions/3/assets","GET"),("/api/interview-sessions/3","DELETE"),("/api/interview-assets/4/content","GET"),
                ("/api/interview-sessions/3/prep-items:generate","POST")})
            Assert.True(CareerRequest.Allowed(path,method),$"{method} {path}");
        foreach(var (path,method) in new[]{("/api/interview-sessions/3/prep-items:generate","GET"),("/api/interview-sessions/3/transcriptions/4:drop","POST"),
                ("/api/interview-sessions/3/review-notes/x","DELETE"),("/api/interview-assets/4","DELETE"),("/api/interview-sessions/3/review:generate","GET")})
            Assert.False(CareerRequest.Allowed(path,method),$"{method} {path}");
    }

    [Fact] public void writtenImportMultipartCarriesOnlyTheChosenSource() {
        var (text,type)=CareerUpload.WrittenImport(Json("""{"source":"text","text":"1. 题目"}"""));
        Assert.StartsWith("multipart/form-data; boundary=",type);
        var body=Encoding.UTF8.GetString(text);
        Assert.True(body.Contains("name=\"source\"\r\n\r\ntext\r\n")&&body.Contains("1. 题目")&&!body.Contains("dataset_id"));
        var error=Assert.Throws<ApiException>(()=>CareerUpload.WrittenImport(Json("""{"source":"images","images":[{"base64":"AAAA","content_type":"image/gif"}]}""")));
        Assert.True(error.Status==HttpStatusCode.BadRequest&&error.Code=="INTERVIEW_IMPORT_IMAGE_INVALID");
        Assert.Throws<InvalidDataException>(()=>CareerUpload.WrittenImport(Json("""{"source":"dataset","dataset_id":"0"}""")));
    }
}
