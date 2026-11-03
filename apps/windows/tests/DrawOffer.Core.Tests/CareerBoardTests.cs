using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;

/// <summary>Mac `CareerBoardTests.swift` 的逐条移植。</summary>
public class CareerBoardTests {
    private static JsonNode Raw(string source)=>JsonNode.Parse(source)!;
    private static readonly TimeZoneInfo Utc=TimeZoneInfo.Utc;

    [Fact] public void boardCardCopyFollowsWebProjection() {
        var now=CareerApplication.Date("2030-01-05T08:00:00Z")!.Value;
        var pending=Raw("""{"status":"active","phase":"pending","current_stage_type":"screening","current_stage_label":"待投递","created_at":"2030-01-02T03:04:00Z"}""");
        Assert.Equal("等待确认投递",CareerBoard.CardStatus(pending,false,now));
        Assert.Equal("创建于 1月2日 03:04",CareerBoard.CardTime(pending,Utc));

        var today=Raw("""{"status":"active","phase":"applied","current_stage":{"id":"1","stage_type":"interview","stage_label":"技术二面"},"current_stage_type":"interview","stage_state":"scheduled","next_session_start_at":"2030-01-05T10:00:00Z","next_session_end_at":"2030-01-05T11:00:00Z"}""");
        Assert.Equal("2 小时后",CareerBoard.CardStatus(today,false,now));
        Assert.Equal("今天 10:00",CareerBoard.Today(today,now,Utc));
        Assert.Equal("1月5日 10:00–11:00",CareerBoard.CardTime(today,Utc));
        Assert.Equal(CareerTone.Blue,CareerBoard.Tone(today,false,now));
        Assert.Equal("技术二面 · 2 小时后",CareerBoard.ProgressLabel(today,false,now));

        var later=CareerApplication.Date("2030-01-05T12:00:00Z")!.Value;
        Assert.Equal("等待结果",CareerBoard.CardStatus(today,false,later));
        Assert.Equal(CareerTone.Orange,CareerBoard.Tone(today,false,later));
        Assert.Equal("已完成",CareerBoard.CardStatus(today,true,later));
        Assert.Equal(CareerTone.Green,CareerBoard.Tone(today,true,later));

        var rejected=Raw("""{"status":"rejected","lifecycle_status":"terminated","termination_reason":"company_rejected","current_stage":{"stage_type":"interview","stage_label":"一面"}}""");
        Assert.Equal("结束阶段：一面",CareerBoard.CardStatus(rejected,false,now));
        Assert.Equal("一面 · 未通过",CareerBoard.ProgressLabel(rejected,false,now));
        Assert.Equal(CareerTone.Red,CareerBoard.Tone(rejected,false,now));

        var oc=Raw("""{"status":"active","phase":"applied","current_stage":{"stage_type":"oc","stage_label":"OC"},"current_stage_type":"oc","offer_status":"none"}""");
        Assert.Equal("口头意向",CareerBoard.CardStatus(oc,false,now));
        Assert.Equal(CareerTone.Green,CareerBoard.Tone(oc,false,now));
    }

    [Fact] public void acceptedOfferStaysInOfferColumn() {
        var accepted=new CareerApplication(Raw("""{"id":"1","status":"closed","current_stage_type":"offer","offer_status":"accepted"}"""));
        Assert.Equal("offer",accepted.Column);
        Assert.False(accepted.Movable);
        Assert.Equal("已收到 Offer",CareerBoard.CardStatus(accepted.Raw,false));
    }

    [Fact] public void relativeDayMatchesListCopy() {
        var now=CareerApplication.Date("2030-01-05T08:00:00Z")!.Value;
        Assert.Equal("今天 07:05",CareerBoard.RelativeDay("2030-01-05T07:05:00Z",now,Utc));
        Assert.Equal("昨天 07:05",CareerBoard.RelativeDay("2030-01-04T07:05:00Z",now,Utc));
        Assert.Equal("12月24日",CareerBoard.RelativeDay("2029-12-24T07:05:00Z",now,Utc));
    }
}
