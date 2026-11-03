using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;

/// <summary>Mac `InterviewRecordTests.swift` 的逐条移植。</summary>
public class InterviewRecordTests {
    [Fact] public void recordParsesTurnsFollowUpsAndReplies() {
        var markdown="面试官：讲讲订单服务\n\n我：拆单和预占\n\n面试官（追问）：对账挂了怎么办\n\n我：重跑并告警\n\n面试官：团队多大？\n\n面试官（回答）：八个人";
        var questions=InterviewRecord.Parse(markdown);
        Assert.Equal(2,questions.Count);
        Assert.Equal("拆单和预占",questions[0].Answer);
        Assert.Equal(new[]{new RecordFollowUp("对账挂了怎么办","重跑并告警")},questions[0].FollowUps);
        Assert.Equal("团队多大？",questions[1].Question);
        Assert.Equal("八个人",questions[1].Reply);
        Assert.Equal(questions,InterviewRecord.Parse(InterviewRecord.Serialize(questions)));
    }

    [Fact] public void recordReadsNumberedListsAndUnnamedSpeakers() {
        Assert.Equal(new[]{"自我介绍","为什么换工作"},InterviewRecord.Parse("1. 自我介绍\n讲了项目\n2. 为什么换工作").Select(x=>x.Question));
        var speakers=InterviewRecord.Parse("说话人 1：你好，介绍一下\n\n说话人 2：我做前端");
        Assert.Single(speakers);
        Assert.Equal("我做前端",speakers[0].Answer);
    }

    [Fact] public void careerDeckBuildsApplyAndScreeningStations() {
        var now=CareerApplication.Date("2030-01-05T08:00:00Z")!.Value;
        var app=JsonNode.Parse("""
        {"id":"9","status":"active","lifecycle_status":"active","phase":"applied","offer_status":"none","stage_state":"awaiting_result",
         "applied_at":"2030-01-02T08:00:00Z","created_at":"2030-01-01T08:00:00Z","updated_at":"2030-01-02T08:00:00Z","applied_channel":"官网",
         "current_stage":{"id":"s1","stage_type":"screening"},
         "stages":[{"id":"s1","stage_type":"screening","stage_label":"简历筛选","sequence_no":1,"stage_result":"pending","current_marker":1,"entered_at":"2030-01-02T08:00:00Z","updated_at":"2030-01-02T08:00:00Z"}]}
        """)!;
        var deck=new CareerDeck(app,[],now);
        Assert.Equal(new[]{"投递","筛选"},deck.Stations.Select(x=>x.Short));
        Assert.Equal("简历筛选",deck.Current?.Title);
        Assert.True(deck.Days==3&&deck.DaysLabel=="已投递");
        var line=deck.Line(now);
        Assert.Equal("下一站",line.Next);
        var wait=Assert.IsType<CareerLineRow.Wait>(line.Stations[1].Rows[1]);
        Assert.Equal("等筛选 · 第 3 天",wait.Label);
    }
}
