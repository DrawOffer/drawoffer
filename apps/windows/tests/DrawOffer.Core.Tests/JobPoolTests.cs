using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;

/// <summary>Mac `JobPoolTests.swift` 的逐条移植。</summary>
public class JobPoolTests {
    [Fact] public void jobPoolSplitsOfficialBodyIntoSectionsAndPoints() {
        var text="负责虚构产品的后端服务\n岗位职责：\n1、设计接口\n2. 维护数据\n任职要求：本科及以上\n- 熟悉 Python\n加分项";
        var sections=JobPool.Sections(text);
        Assert.Equal(new[]{"岗位描述","岗位职责","任职要求"},sections.Select(x=>x.Title));
        Assert.Equal(new JobPool.Block[]{new JobPool.Block.Points(["设计接口","维护数据"])},sections[1].Blocks);
        Assert.Equal(new JobPool.Block[]{new JobPool.Block.Paragraph("本科及以上"),new JobPool.Block.Points(["熟悉 Python"])},sections[2].Blocks);
        Assert.Empty(JobPool.Sections(""));
    }

    [Fact] public void jobPoolFormatsRecruitmentAndRelativeTime() {
        var zone=TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
        var now=DateTimeOffset.Parse("2026-10-30T04:00:00Z");
        Assert.Equal("今天",JobPool.Relative("2026-10-30T01:00:00Z",now,zone));
        Assert.Equal("3 天前",JobPool.Relative("2026-10-27T01:00:00Z",now,zone));
        Assert.Equal("2 周前",JobPool.Relative("2026-10-16T01:00:00Z",now,zone));
        Assert.Equal("2025年9月1日",JobPool.Relative("2025-09-01T01:00:00Z",now,zone));
        var job=new JsonObject{["employment_type"]="full_time",["recruitment_channel"]="campus"};
        Assert.Equal("校招",JobPool.Recruitment(job));
        Assert.Equal("校招 · 正式",JobPool.JobType(job));
    }
}
