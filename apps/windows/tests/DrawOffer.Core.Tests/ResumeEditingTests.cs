using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;

namespace DrawOffer.Core.Tests;

/// <summary>与 Mac `ResumeEditingTests.swift` 逐条相同的用例与数据。</summary>
public sealed class ResumeEditingTests
{
    static JsonNode J(string source) => JsonNode.Parse(source)!;

    const string TwoColumnStyle = """
{"schema_version":"resume-presentation.v1","portable":{"smart_one_page":false},"template_scoped":{},
 "template_snapshot":{"template_key":"fixture-two","regions":[{"region_id":"side","region_kind":"sidebar","order":1},{"region_id":"main","region_kind":"main","order":2}],
  "slots":[{"slot_id":"s-identity","region_id":"side","accepts":["identity","skills"],"universal_fallback":false,"order":1},
           {"slot_id":"s-rest","region_id":"main","accepts":["identity","profile","work","education","project","skills","activity","interests","certificates","awards","languages","custom"],"universal_fallback":true,"order":2}],
  "tokens":{"font_family":"source-han-serif","font_size_pt":10,"line_height":1.5,"accent_color":"#2F4858","page_margin_mm":16}}}
""";

    const string Document = """
{"identity":{"node_id":"node_identity"},"sections":[
 {"node_id":"node_work","semantic_kind":"work"},{"node_id":"node_skills","semantic_kind":"skills"},{"node_id":"node_profile","semantic_kind":"profile"}]}
""";

    [Fact]
    public void LocalLayoutPlanRoutesEachTopLevelNodeOnce()
    {
        var plan = ResumeLayout.Compile(J(Document), J(TwoColumnStyle), "sha256:x");
        Assert.NotNull(plan);
        var regions = plan["regions"]!.AsArray();
        Assert.Equal(["side", "main"], regions.Select(x => x.Text("region_id")));
        Assert.Equal(["node_identity", "node_skills"], regions[0]!["nodes"]!.AsArray().Select(x => x.Text("node_id")));
        Assert.Equal(["node_work", "node_profile"], regions[1]!["nodes"]!.AsArray().Select(x => x.Text("node_id")));
        Assert.Equal("sidebar", ResumeLayout.Columns(J(Document), J(TwoColumnStyle))["node_skills"]);
    }

    [Fact]
    public void TypeSettingsRoundTripThroughPresentation()
    {
        var style = J(TwoColumnStyle);
        var settings = ResumeTypeSettings.Read(style);
        Assert.NotNull(settings);
        Assert.True(settings.FontSize == 10 && settings.PageMargin == 16 && settings.FontFamily == ResumeTypeSettings.SerifStack);
        settings.FontSize = 11; settings.PageMargin = 20; settings.SmartOnePage = true;
        var next = settings.Apply(style);
        var scoped = next.Get("template_scoped").Get("fixture-two");
        Assert.Equal(1.1, scoped.Number("font_scale"));
        Assert.Equal(20, scoped.Number("page_margin_left_mm"));
        Assert.False((scoped as JsonObject)!.ContainsKey("page_margin_top_mm"));
        Assert.Equal("source-han-serif", scoped.Get("font_family").String());
        Assert.Equal(settings, ResumeTypeSettings.Read(next));
        Assert.Equal(1.55, ResumeTypeSettings.Step(1.5, 1, 1.1, 1.8, 0.05));
    }

    [Fact]
    public void CarriedZeroMarginDoesNotReplaceTheActiveTemplateInset()
    {
        const string source = """
        {"schema_version":"resume-presentation.v1",
         "portable":{"page_margin_mm":10,"vertical_page_margin_mm":0,"page_margin_top_mm":0,"page_margin_right_mm":0,"page_margin_bottom_mm":8,"page_margin_left_mm":10},
         "template_scoped":{"muse-badge-cn":{}},
         "template_snapshot":{"template_key":"muse-badge-cn","tokens":{"font_family":"source-han-serif","font_size_pt":10,"line_height":1.5,"accent_color":"#2F4858","page_margin_mm":12}}}
        """;
        var settings = ResumeTypeSettings.Read(J(source));
        Assert.NotNull(settings);
        Assert.True(settings.PageMargin == 10 && settings.VerticalPageMargin == 12);
    }

    [Fact]
    public void TextRunsKeepValueInSyncAndDropPlainRuns()
    {
        var bold = ResumeDocument.TextRun("张", ["bold"]);
        var plain = ResumeDocument.TextRun("三");
        var value = ResumeDocument.SetTextRuns(null, [bold, plain, ResumeDocument.TextRun("")]);
        Assert.NotNull(value);
        Assert.Equal("张三", value.Text("value"));
        Assert.Equal(2, value["runs"]!.AsArray().Count);
        var flattened = ResumeDocument.SetTextRuns(value, [ResumeDocument.TextRun("张"), ResumeDocument.TextRun("三")]);
        Assert.NotNull(flattened);
        Assert.True(flattened.Text("value") == "张三" && !((JsonObject)flattened).ContainsKey("runs") && flattened.Text("node_id") == value.Text("node_id"));
        Assert.Null(ResumeDocument.SetTextRuns(value, []));
        var merged = ResumeDocument.NormalizeRuns([plain, plain, new JsonObject { ["inline_type"] = "icon", ["name"] = "Mail" }, plain]);
        Assert.True(merged.Count == 3 && merged[0].Text("text") == "三三");
    }

    [Fact]
    public void CollegeIsAnEditableEntryField()
    {
        Assert.Contains(ResumeDocument.EntryFields, x => x.Key == "college" && x.Label == "学院");
        var college = ResumeDocument.SetTextRuns(null, [ResumeDocument.TextRun("计算机学院")]);
        Assert.NotNull(college);
        var changed = ResumeDocument.SetTextRuns(college, [ResumeDocument.TextRun("软件学院")]);
        Assert.NotNull(changed);
        Assert.Equal("软件学院", changed.Text("value"));
        Assert.Equal(college.Text("node_id"), changed.Text("node_id"));
    }

    [Fact]
    public void SectionOrderRestoresCanonicalKinds()
    {
        var sections = J(Document)["sections"]!.AsArray().ToList();
        Assert.Equal(["node_profile", "node_work", "node_skills"], ResumeSectionOrder.RestoreDefault(sections).Select(x => x.Text("node_id")));
    }

    [Fact]
    public void NewBlocksMatchCanonicalShapes()
    {
        var pair = ResumeDocument.NewRow("pair");
        Assert.True(pair["cells"]!.AsArray().Count == 2 && pair.Number("left_width_percent") == 50);
        var meta = ResumeDocument.NewRow("meta");
        Assert.True(meta.ContainsKey("left_width_percent") && meta["left_width_percent"] is null);
        Assert.Equal("%", ResumeDocument.NewImage("/api/resumes/1/assets/a.png", null)["width_unit"].String());
        Assert.True(ResumeDocument.ValidImageSource("/api/resumes/1/assets/a.png"));
        Assert.False(ResumeDocument.ValidImageSource("file:///tmp/a.png"));
        var avatar = ResumeDocument.Avatar(null, "/api/resumes/1/assets/a.png");
        Assert.True(avatar.Number("width") == 96 && avatar.ContainsKey("align") && avatar["align"] is null && avatar.Text("media_kind") == "avatar");
    }

    [Fact]
    public void SectionFocusBuildsLinesAndReplacesOneLine()
    {
        var entry = new JsonObject
        {
            ["node_id"] = "node_entry_fixture_000001",
            ["fields"] = new JsonObject { ["organization"] = new JsonObject { ["value"] = "虚构科技公司" } },
            ["blocks"] = new JsonArray(new JsonObject
            {
                ["node_id"] = "node_list_fixture_00001", ["block_type"] = "bullet_list",
                ["items"] = new JsonArray(new JsonObject { ["node_id"] = "node_item_fixture_00001", ["runs"] = ResumeDocument.PlainRuns("负责前端开发") }),
            }),
        };
        var unit = SectionFocus.UnitOf(entry);
        Assert.NotNull(unit);
        Assert.Equal("虚构科技公司", unit.Heading);
        Assert.Equal([new SectionFocus.Line("node_item_fixture_00001", "负责前端开发")], unit.Lines);
        var document = new JsonObject { ["sections"] = new JsonArray(new JsonObject { ["entries"] = new JsonArray(entry.DeepClone()) }) };
        var next = SectionFocus.Replacing(document, "node_item_fixture_00001", "主导前端重构，首屏耗时降低 40%");
        Assert.NotNull(next);
        var item = next["sections"]![0]!["entries"]![0]!["blocks"]![0]!["items"]![0];
        Assert.Equal("主导前端重构，首屏耗时降低 40%", ResumeDocument.RunsText(item.Get("runs")));
        Assert.Null(SectionFocus.Replacing(document, "missing", "x"));
    }
}
