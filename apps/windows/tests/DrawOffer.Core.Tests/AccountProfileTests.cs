using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;

namespace DrawOffer.Core.Tests;

public class AccountProfileTests
{
    [Fact]
    public void AvatarCropMatchesWeb()
    {
        var layout=AvatarCrop.Measure(new(640,480));
        Assert.Equal(352,layout.RenderedWidth);Assert.Equal(264,layout.RenderedHeight);
        Assert.Equal(44,layout.MaxOffsetX);Assert.Equal(0,layout.MaxOffsetY);Assert.Equal(.55,layout.Scale,9);
        var clamped=AvatarCrop.Clamp(new(640,480,OffsetX:100,OffsetY:100));
        Assert.Equal(44,clamped.OffsetX);Assert.Equal(0,clamped.OffsetY);
        var source=AvatarCrop.Source(new(640,480,Zoom:2));
        Assert.Equal(200,source.X,6);Assert.Equal(120,source.Y,6);Assert.Equal(240,source.Size,6);
    }

    [Theory]
    [InlineData(480,640,1,-999,999)]
    [InlineData(640,480,3,999,-999)]
    [InlineData(512,512,9,0,0)]
    public void CropStaysInsideSource(double width,double height,double zoom,double x,double y)
    {
        var draft=AvatarCrop.Clamp(new(width,height,zoom,x,y));var source=AvatarCrop.Source(draft);
        Assert.InRange(draft.Zoom,1,3);Assert.InRange(source.X,0,width-source.Size);
        Assert.InRange(source.Y,0,height-source.Size);Assert.InRange(source.Size,1,Math.Min(width,height));
    }

    [Fact]
    public void CareerProfileMatchesMac()
    {
        var profile=JsonNode.Parse("""{"personal":{"name":"虚构","email":"a@example.com"},"has_id_number":false,"catalog":{"fields":{"a":{"scope":"personal","key":"height","label":"身高"},"b":{"scope":"personal","key":"name","label":"姓名"},"c":{"scope":"personal","key":"x","label":"站点","site":"example"}}}}""")!;
        Assert.Equal(new[]{"gender","birth_date","phone","ethnicity","political_status","native_place","id_number"},CareerProfileRules.Missing(profile));
        Assert.Equal(new[]{"height"},CareerProfileRules.MoreRows(profile).Select(x=>x.Key));
        var experience=JsonNode.Parse("""{"sections":[{"kind":"work","entries":[{"id":"1","fields":{"单位":"虚构公司"},"intern":true}]},{"kind":"skills","lines":["编程：Swift、Python；工具: Git"],"entries":[]}]}""")!;
        var group=Assert.Single(CareerProfileRules.Groups(experience));Assert.Equal("internship",group.Key);
        Assert.Equal("虚构公司",CareerProfileRules.EntryTitle(Assert.Single(group.Items).Entry));
        Assert.Equal(new[]{"Swift","Python","Git"},CareerProfileRules.Skills(experience).Select(x=>x.Name));
        Assert.Equal("15K–25K / 月",CareerProfileRules.SalaryText(JsonNode.Parse("""{"salary_min":15000,"salary_max":25000,"salary_period":"month"}""")!));
    }

    [Fact]
    public void ExplicitSkillsOverrideImportedText()
    {
        var experience=JsonNode.Parse("""{"skills":[{"name":"C#","level":"proficient"}],"sections":[{"kind":"skills","lines":["旧技能"]}]}""");
        var skill=Assert.Single(CareerProfileRules.Skills(experience));Assert.Equal("C#",skill.Name);Assert.Equal("proficient",skill.Level);
    }
}
