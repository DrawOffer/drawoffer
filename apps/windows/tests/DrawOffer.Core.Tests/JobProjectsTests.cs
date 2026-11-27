using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;

/// <summary>Mac `JobProjectsTests.swift` 的逐条移植。</summary>
public class JobProjectsTests {
    private static JsonNode Json(string text)=>JsonNode.Parse(text)!;
    private static JsonNode Application(string extra="",string id="a1",string updated="2026-09-12T02:00:00Z")=>
        Json("{\"id\":\""+id+"\",\"company_name_snapshot\":\"虚构甲公司\",\"job_title_snapshot\":\"后端开发\",\"phase\":\"applied\",\"offer_status\":\"received\",\"offer_received_on\":null,\"applied_at\":\"2026-09-12T02:00:00Z\",\"created_at\":\"2026-09-10T02:00:00Z\",\"updated_at\":\""+updated+"\""+extra+"}");
    private static JsonNode Session(string id,string label="一面",string status="completed",string start="2026-09-26T02:00:00Z")=>
        Json("{\"id\":\""+id+"\",\"application_id\":\"a1\",\"stage_label\":\""+label+"\",\"status\":\""+status+"\",\"start_at\":\""+start+"\"}");
    private static DatasetRecord Dataset(string id,string extra="")=>
        new(Json("{\"id\":\""+id+"\",\"folder_id\":null,\"file_name\":\""+id+".md\",\"file_format\":\"md\",\"file_size\":10,\"upload_status\":\"succeeded\",\"parse_status\":\"succeeded\",\"created_at\":\"2026-09-27T02:00:00Z\""+extra+"}"));

    /// <summary>与 Web `jobProjects.test.ts` 同样的三组用例。</summary>
    [Fact] public void jobProjectsMatchWeb() {
        var projects=JobProjects.Build(
            [Application(",\"offer_materials\":[{\"dataset_id\":\"d3\",\"file_name\":\"offer.pdf\"}]")],
            [Session("s2",label:"二面",status:"scheduled",start:"2026-10-08T02:00:00Z"),Session("s1"),Session("s0",label:"已取消",status:"cancelled")],
            [Dataset("d1",",\"interview_session_id\":\"s1\",\"asset_kind\":\"audio\""),Dataset("d2",",\"interview_session_id\":\"s1\""),Dataset("d3"),Dataset("d4",",\"interview_session_id\":null")]);
        var project=projects[0];
        Assert.Equal("虚构甲公司 · 后端开发",project.Name);
        Assert.Equal("虚",project.Monogram);
        Assert.Equal("已获 Offer",project.StatusLabel);
        Assert.Equal(new[]{"投递|Done","一面|Done","二面|Current","Offer|Offer"},project.Nodes.Select(x=>$"{x.Label}|{x.State}"));
        Assert.Equal(new[]{"d1","d2"},project.Nodes[1].Datasets.Select(x=>x.Id));
        Assert.Equal(new[]{"d3"},project.Nodes[3].Datasets.Select(x=>x.Id));
        Assert.Equal(3,project.DatasetCount);
        Assert.Equal("session-s2",project.FocusKey);
        Assert.Equal("3 份资料",project.MaterialSummary);

        var sorted=JobProjects.Build([
            Json("""{"id":"pending","phase":"pending","company_name_snapshot":"","job_title_snapshot":""}"""),
            Application(",\"archived_at\":\"2026-10-01T00:00:00Z\",\"offer_materials\":[]",id:"archived",updated:"2026-10-09T00:00:00Z"),
            Application(id:"active",updated:"2026-09-01T00:00:00Z"),
        ],[],[]);
        Assert.Equal(new[]{"active","archived"},sorted.Select(x=>x.Id));
        Assert.Equal("已归档",sorted[1].StatusLabel);

        var labelled=JobProjects.Build([Application()],[Session("s1")],[Dataset("d1",",\"interview_session_id\":\"s1\"")]);
        Assert.Equal("虚构甲公司 · 后端开发",JobProjects.Labels(labelled)["d1"]);
        double[] sizes=[88,1536,524_288_000,1_073_741_824];
        Assert.Equal(new[]{"88 B","1.5 KB","500 MB","1 GB"},sizes.Select(JobProjects.Size));
    }
}
