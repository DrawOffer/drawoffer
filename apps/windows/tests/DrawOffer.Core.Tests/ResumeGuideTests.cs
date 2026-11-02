using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;
using G = DrawOffer.Core.Models.ResumeGuideModel;

namespace DrawOffer.Core.Tests;

/// <summary>与 Mac `ResumeGuideTests.swift`（即 Web `guide/guideModel.test.ts`）同样的用例：引导的预填、写法推断与写入。</summary>
public sealed class ResumeGuideTests
{
    static JsonNode Text(string id, string value) => new JsonObject { ["node_id"] = id, ["source_refs"] = new JsonArray(), ["value"] = value };
    static JsonNode Run(string value) => new JsonObject { ["inline_type"] = "text", ["text"] = value, ["marks"] = new JsonArray() };
    static JsonNode Paragraph(string id, string line) => new JsonObject { ["node_id"] = id, ["block_type"] = "paragraph", ["runs"] = new JsonArray(Run(line)) };

    static JsonNode Document(params JsonNode[] sections) => new JsonObject
    {
        ["identity"] = new JsonObject { ["node_id"] = "node_identity", ["name"] = Text("node_name", "林晓"), ["headline"] = null, ["contacts"] = new JsonArray() },
        ["sections"] = new JsonArray(sections.Select(x => (JsonNode?)x.DeepClone()).ToArray()),
    };

    static JsonNode Section(string id, string kind, JsonNode[]? entries = null, JsonNode[]? blocks = null, string? title = null) => new JsonObject
    {
        ["node_id"] = id, ["semantic_kind"] = kind, ["title"] = title is null ? null : Text(id + "_t", title),
        ["entries"] = new JsonArray((entries ?? []).Select(x => (JsonNode?)x.DeepClone()).ToArray()),
        ["blocks"] = new JsonArray((blocks ?? []).Select(x => (JsonNode?)x.DeepClone()).ToArray()),
    };

    static JsonNode Skills(string line) => Section("node_skills", "skills", blocks: [Paragraph("node_skills_p", line)], title: "专业技能");
    static readonly HashSet<string> None = [];

    static void Same(JsonNode? expected, JsonNode? actual) => Assert.True(JsonNode.DeepEquals(expected, actual), $"expected {expected?.ToJsonString()} got {actual?.ToJsonString()}");

    [Fact]
    public void ReadsSkillNamesAndLevels()
    {
        Assert.Equal(["Java=proficient", "MySQL=proficient", "Kafka=basic"], G.SkillsOnPaper(Document(Skills("熟练：Java、MySQL；了解：Kafka"))).Select(x => $"{x.Name}={x.Level ?? "-"}"));
        Assert.Equal(["Go", "Redis", "Docker"], G.SkillsOnPaper(Document(Skills("Go, Redis / Docker"))).Select(x => x.Name));
        Assert.Equal(["React", "TypeScript"], G.SkillsOnPaper(Document(Skills("React、TypeScript：组件拆分、状态建模与复杂表单开发。"))).Select(x => x.Name));
        Assert.Equal(["Java", "Go"], G.SkillsOnPaper(Document(Skills("编程语言：Java、Go"))).Select(x => x.Name));
        Assert.Equal(["并发编程=familiar"], G.SkillsOnPaper(Document(Skills("2. 并发编程：熟悉JMM、volatile与锁升级机制"))).Select(x => $"{x.Name}={x.Level ?? "-"}"));
    }

    [Fact]
    public void Headline()
    {
        var intent = new G.JobIntent { Role = "后端开发", Cities = ["杭州", "上海"], GraduationYear = "2026" };
        Assert.Equal("后端开发 · 2026 届 · 杭州 / 上海", G.JobIntentHeadline(intent));
        intent.Cities = []; intent.GraduationYear = "26";
        Assert.Equal("后端开发", G.JobIntentHeadline(intent));
    }

    [Fact]
    public void EducationFromMaterialsWritesNewEntry()
    {
        var entry = new JsonObject
        {
            ["node_id"] = "m_e1",
            ["fields"] = new JsonObject { ["name"] = Text("m_n", "示例大学"), ["major"] = Text("m_m", "软件工程"), ["degree"] = Text("m_d", "本科"), ["start_date"] = Text("m_s", "2022.09") },
            ["blocks"] = new JsonArray(new JsonObject
            {
                ["node_id"] = "m_b", ["block_type"] = "bullet_list",
                ["items"] = new JsonArray(new JsonObject { ["node_id"] = "m_i", ["runs"] = new JsonArray(Run("GPA 3.6/4.0；主修课程：数据结构、操作系统")) }),
            }),
        };
        var materials = Document(Section("m_edu", "education", entries: [entry]));
        var form = G.Education(Document(), materials, new JsonObject { ["graduation_year"] = 2026.0 }, None);
        Assert.Null(form.EntryID);
        Assert.Equal(["示例大学", "软件工程", "本科", "2022.09", "2026.06", "3.6/4.0", "数据结构、操作系统"],
            new[] { form.School, form.Major, form.Degree, form.Start, form.End, form.Gpa, form.Courses });
        var ops = G.EducationOperations(form);
        Same(new JsonObject
        {
            ["name"] = "示例大学", ["paragraphs"] = new JsonArray("2022.09—2026.06｜软件工程 · 本科"), ["bullets"] = new JsonArray("GPA 3.6/4.0；主修课程：数据结构、操作系统"),
        }, ops.FirstOrDefault()?["entries"]?[0]);
    }

    [Fact]
    public void FollowsTemplateShape()
    {
        var entry = new JsonObject
        {
            ["node_id"] = "e1", ["fields"] = new JsonObject { ["name"] = Text("e1_n", "示例理工大学") },
            ["blocks"] = new JsonArray(Paragraph("e1_p1", "2019.09 — 2023.06"), Paragraph("e1_p2", "本科 · 软件工程；主修数据结构")),
        };
        var paper = Document(Section("s_edu", "education", entries: [entry]));
        var form = new G.EducationForm { School = "安徽工业大学", Major = "人工智能", Degree = "本科", Start = "2023.09", End = "2027.06", Gpa = "3.6/4.0" };
        Same(new JsonObject { ["name"] = "安徽工业大学", ["paragraphs"] = new JsonArray("2023.09 — 2027.06", "本科 · 人工智能；GPA 3.6/4.0") },
            G.EducationOperations(form, G.EntryFormatOf([paper, null], ["education"])).FirstOrDefault()?["entries"]?[0]);
        var back = G.Education(paper, null, null, None);
        Assert.Equal(["e1", "软件工程", "本科", "2019.09", "2023.06"], new[] { back.EntryID ?? "", back.Major, back.Degree, back.Start, back.End });

        var template = Document(Section("t_edu", "education", entries:
        [
            new JsonObject { ["node_id"] = "t1", ["fields"] = new JsonObject { ["name"] = Text("t1_n", "示例财经大学｜2023.09—2027.06（预计毕业）｜电子商务 · 本科") }, ["blocks"] = new JsonArray() },
        ], title: "教育背景"));
        form.Gpa = "";
        var ops = G.EducationOperations(form, G.EntryFormatOf([Document(), template], ["education"]), "教育背景");
        Same(JsonValue.Create("教育背景"), ops.FirstOrDefault()?["title"]);
        Same(JsonValue.Create("安徽工业大学｜2023.09—2027.06｜人工智能 · 本科"), ops.FirstOrDefault()?["entries"]?[0]?["name"]);
        Assert.Equal(G.DefaultFormat, G.EntryFormatOf([Document(), null], ["education"]));
    }

    [Fact]
    public void Dates()
    {
        var dot = new G.DateStyle(".", true);
        Assert.Equal(["2024.03", "2024.03", "2024.03", "2024.03", "2024", "至今", "去年夏天"],
            new[] { "2024.3", "2024-03", "2024年3月", "202403", "2024", "现在", "去年夏天" }.Select(x => G.NormalizeDate(x, dot)));
        Assert.Equal("2024年3月", G.NormalizeDate("2024.03", new G.DateStyle("年", false)));
        var paper = Document(Section("s_work", "work", entries:
        [
            new JsonObject { ["node_id"] = "w1", ["fields"] = new JsonObject { ["name"] = Text("w1_n", "虚构甲公司") }, ["blocks"] = new JsonArray(Paragraph("w1_p", "2024/07 - 2024/09｜后端实习")) },
        ]));
        Assert.Equal(["2025/07 - 至今｜后端实习"], G.EntryLines(G.EntryFormatOf([paper], ["work"]), "虚构乙公司", "2025.7", "至今", "后端实习").Paragraphs);
    }

    [Fact]
    public void MatchingEntry()
    {
        var paper = Document(Section("s_work", "work", entries:
        [
            new JsonObject { ["node_id"] = "w1", ["fields"] = new JsonObject { ["name"] = Text("w1_n", "虚构星河时空科技有限公司") }, ["blocks"] = new JsonArray(Paragraph("w1_p", "2025.03—2025.07｜后端开发工程师")) },
        ]));
        var form = new G.ExperienceForm { Name = "虚构星河时空股份有限公司", Start = "2025.03", End = "2025.08", Did = "x" };
        Assert.Equal(G.NameCore("虚构星河时空科技有限公司"), G.NameCore("虚构星河时空股份有限公司"));
        Assert.Equal("w1", G.MatchingEntry(paper, form, None));
        form.Start = "2026.01"; form.End = "2026.03";
        Assert.Null(G.MatchingEntry(paper, form, None));
    }

    [Fact]
    public void SkillPoints()
    {
        JsonNode?[] lines =
        [
            new JsonObject
            {
                ["direction"] = "并发编程", ["text"] = "",
                ["layers"] = new JsonArray(
                    new JsonObject { ["level"] = "familiar", ["points"] = new JsonArray(new JsonObject { ["text"] = "JMM", ["source"] = "catalog" }, new JsonObject { ["text"] = "volatile", ["source"] = "user" }) },
                    new JsonObject { ["level"] = "proficient", ["points"] = new JsonArray(new JsonObject { ["text"] = "AQS 原理", ["source"] = "model", ["weak"] = true }) }),
            },
        ];
        Assert.Equal("并发编程：熟悉JMM、volatile，熟练掌握AQS 原理", G.SkillLineText(lines[0]));
        Assert.Equal(["AQS 原理", "JMM"], G.AddedPoints(lines).Select(x => x.Text));
        var next = G.WithoutPoint(lines, 0, "AQS 原理");
        Assert.Single(next[0]!["layers"]!.AsArray());
        Assert.Equal("并发编程：熟悉JMM、volatile", next[0].Text("text"));
    }

    [Fact]
    public void Honors()
    {
        JsonNode List(string kind, string[] lines) => Section($"s_{kind}", kind, blocks:
        [
            new JsonObject
            {
                ["node_id"] = $"b_{kind}", ["block_type"] = "bullet_list",
                ["items"] = new JsonArray(lines.Select((x, i) => (JsonNode?)new JsonObject { ["node_id"] = $"i_{kind}_{i}", ["runs"] = new JsonArray(Run(x)) }).ToArray()),
            },
        ]);
        var form = G.HonorsFormOf(Document(List("awards", ["示例奖学金"])), Document(List("certificates", ["英语六级 560"])),
            new JsonObject { ["honors"] = new JsonArray("校一等奖学金") }, new HashSet<string> { "s_awards" });
        Assert.Equal(["英语六级 560", "校一等奖学金"], new[] { form.Certificates, form.Awards });
        var input = new G.HonorsForm { Certificates = "英语六级 560\n", Awards = "· 校一等奖学金" };
        Same(new JsonArray("英语六级 560", "校一等奖学金"), G.HonorsOperations(input, new HashSet<string> { "certificates" }).FirstOrDefault()?["bullets"]);
        Assert.Equal(["awards", "certificates"], G.HonorsOperations(input, None).Select(x => x.Text("semantic_kind")));
        Assert.Empty(G.HonorsOperations(new G.HonorsForm(), None));
    }

    [Fact]
    public void BasicInfoAndContacts()
    {
        var info = new G.BasicInfo { Name = "林晓" };
        Assert.False(G.BasicInfoReady(info));
        info.Email = "lin@example.com"; info.Link = "https://github.com/example";
        Assert.True(G.BasicInfoReady(info));
        Assert.Equal(["email", "github"], G.BasicInfoOperations(info).FirstOrDefault()?["contacts"]?.AsArray().Select(x => x.Text("kind")));
        var doc = new JsonObject
        {
            ["identity"] = new JsonObject
            {
                ["name"] = Text("n", "林晓"),
                ["contacts"] = new JsonArray(new JsonObject { ["contact_kind"] = "phone", ["value"] = "13800000000" }, new JsonObject { ["contact_kind"] = "website", ["value"] = "example.com" }),
            },
        };
        Assert.Equal(new Dictionary<string, string> { ["name"] = "林晓" }, G.CareerContactChanges(doc, new Dictionary<string, string> { ["phone"] = "1" }));
    }
}
