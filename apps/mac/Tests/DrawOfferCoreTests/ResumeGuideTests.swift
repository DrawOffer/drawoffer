import DrawOfferCore
import Testing

/// 与 Web `guide/guideModel.test.ts` 同样的用例：Mac 引导的预填、写法推断与写入要和 Web 一致。
func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a == b, sourceLocation: sourceLocation) }
func expectNil<T>(_ a: T?, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a == nil, sourceLocation: sourceLocation) }

struct ResumeGuideTests {
    typealias G = ResumeGuideModel

    func text(_ id: String, _ value: String) -> JSONValue { .object(["node_id": .string(id), "source_refs": .array([]), "value": .string(value)]) }
    func run(_ value: String) -> JSONValue { .object(["inline_type": .string("text"), "text": .string(value), "marks": .array([])]) }
    func paragraph(_ id: String, _ line: String) -> JSONValue { .object(["node_id": .string(id), "block_type": .string("paragraph"), "runs": .array([run(line)])]) }
    func document(_ sections: [JSONValue]) -> JSONValue {
        .object(["identity": .object(["node_id": .string("node_identity"), "name": text("node_name", "林晓"), "headline": .null, "contacts": .array([])]),
                 "sections": .array(sections)])
    }
    func section(_ id: String, _ kind: String, entries: [JSONValue] = [], blocks: [JSONValue] = [], title: String? = nil) -> JSONValue {
        .object(["node_id": .string(id), "semantic_kind": .string(kind), "title": title.map { text(id + "_t", $0) } ?? .null,
                 "entries": .array(entries), "blocks": .array(blocks)])
    }
    func skills(_ line: String) -> JSONValue { section("node_skills", "skills", blocks: [paragraph("node_skills_p", line)], title: "专业技能") }

    @Test func readsSkillNamesAndLevels() {
        expectEqual(G.skillsOnPaper(document([skills("熟练：Java、MySQL；了解：Kafka")])).map { "\($0.name)=\($0.level ?? "-")" },
                       ["Java=proficient", "MySQL=proficient", "Kafka=basic"])
        expectEqual(G.skillsOnPaper(document([skills("Go, Redis / Docker")])).map(\.name), ["Go", "Redis", "Docker"])
        expectEqual(G.skillsOnPaper(document([skills("React、TypeScript：组件拆分、状态建模与复杂表单开发。")])).map(\.name), ["React", "TypeScript"])
        expectEqual(G.skillsOnPaper(document([skills("编程语言：Java、Go")])).map(\.name), ["Java", "Go"])
        expectEqual(G.skillsOnPaper(document([skills("2. 并发编程：熟悉JMM、volatile与锁升级机制")])).map { "\($0.name)=\($0.level ?? "-")" }, ["并发编程=familiar"])
    }

    @Test func headline() {
        var intent = G.JobIntent(); intent.role = "后端开发"; intent.cities = ["杭州", "上海"]; intent.graduationYear = "2026"
        expectEqual(G.jobIntentHeadline(intent), "后端开发 · 2026 届 · 杭州 / 上海")
        intent.cities = []; intent.graduationYear = "26"
        expectEqual(G.jobIntentHeadline(intent), "后端开发")
    }

    @Test func educationFromMaterialsWritesNewEntry() {
        let entry: JSONValue = .object(["node_id": .string("m_e1"), "fields": .object([
            "name": text("m_n", "示例大学"), "major": text("m_m", "软件工程"), "degree": text("m_d", "本科"), "start_date": text("m_s", "2022.09")]),
            "blocks": .array([.object(["node_id": .string("m_b"), "block_type": .string("bullet_list"),
                                       "items": .array([.object(["node_id": .string("m_i"), "runs": .array([run("GPA 3.6/4.0；主修课程：数据结构、操作系统")])])])])])])
        let materials = document([section("m_edu", "education", entries: [entry])])
        let form = G.education(document([]), materials: materials, profile: .object(["graduation_year": .number(2026)]), samples: [])
        expectNil(form.entryID)
        expectEqual([form.school, form.major, form.degree, form.start, form.end, form.gpa, form.courses],
                       ["示例大学", "软件工程", "本科", "2022.09", "2026.06", "3.6/4.0", "数据结构、操作系统"])
        let ops = G.educationOperations(form)
        expectEqual(ops.first?["entries"]?.items.first, .object(["name": .string("示例大学"),
            "paragraphs": .array([.string("2022.09—2026.06｜软件工程 · 本科")]), "bullets": .array([.string("GPA 3.6/4.0；主修课程：数据结构、操作系统")])]))
    }

    @Test func followsTemplateShape() {
        let entry: JSONValue = .object(["node_id": .string("e1"), "fields": .object(["name": text("e1_n", "示例理工大学")]),
                                        "blocks": .array([paragraph("e1_p1", "2019.09 — 2023.06"), paragraph("e1_p2", "本科 · 软件工程；主修数据结构")])])
        let paper = document([section("s_edu", "education", entries: [entry])])
        var form = G.EducationForm(); form.school = "安徽工业大学"; form.major = "人工智能"; form.degree = "本科"; form.start = "2023.09"; form.end = "2027.06"; form.gpa = "3.6/4.0"
        expectEqual(G.educationOperations(form, format: G.entryFormat([paper, nil], kinds: ["education"])).first?["entries"]?.items.first,
                       .object(["name": .string("安徽工业大学"), "paragraphs": .array([.string("2023.09 — 2027.06"), .string("本科 · 人工智能；GPA 3.6/4.0")])]))
        let back = G.education(paper, materials: nil, profile: nil, samples: [])
        expectEqual([back.entryID ?? "", back.major, back.degree, back.start, back.end], ["e1", "软件工程", "本科", "2019.09", "2023.06"])

        let template = document([section("t_edu", "education", entries: [.object(["node_id": .string("t1"),
            "fields": .object(["name": text("t1_n", "示例财经大学｜2023.09—2027.06（预计毕业）｜电子商务 · 本科")]), "blocks": .array([])])], title: "教育背景")])
        form.gpa = ""
        let ops = G.educationOperations(form, format: G.entryFormat([document([]), template], kinds: ["education"]), title: "教育背景")
        expectEqual(ops.first?["title"], .string("教育背景"))
        expectEqual(ops.first?["entries"]?.items.first?["name"], .string("安徽工业大学｜2023.09—2027.06｜人工智能 · 本科"))
        expectEqual(G.entryFormat([document([]), nil], kinds: ["education"]), G.defaultFormat)
    }

    @Test func dates() {
        let dot = G.DateStyle(sep: ".", pad: true)
        expectEqual(["2024.3", "2024-03", "2024年3月", "202403", "2024", "现在", "去年夏天"].map { G.normalizeDate($0, dot) },
                       ["2024.03", "2024.03", "2024.03", "2024.03", "2024", "至今", "去年夏天"])
        expectEqual(G.normalizeDate("2024.03", G.DateStyle(sep: "年", pad: false)), "2024年3月")
        let paper = document([section("s_work", "work", entries: [.object(["node_id": .string("w1"), "fields": .object(["name": text("w1_n", "虚构甲公司")]),
                                                                            "blocks": .array([paragraph("w1_p", "2024/07 - 2024/09｜后端实习")])])])])
        expectEqual(G.entryLines(G.entryFormat([paper], kinds: ["work"]), name: "虚构乙公司", start: "2025.7", end: "至今", detail: "后端实习").paragraphs,
                       ["2025/07 - 至今｜后端实习"])
    }

    @Test func matchingEntry() {
        let paper = document([section("s_work", "work", entries: [.object(["node_id": .string("w1"), "fields": .object(["name": text("w1_n", "虚构星河时空科技有限公司")]),
                                                                            "blocks": .array([paragraph("w1_p", "2025.03—2025.07｜后端开发工程师")])])])])
        var form = G.ExperienceForm(); form.name = "虚构星河时空股份有限公司"; form.start = "2025.03"; form.end = "2025.08"; form.did = "x"
        expectEqual(G.nameCore("虚构星河时空科技有限公司"), G.nameCore("虚构星河时空股份有限公司"))
        expectEqual(G.matchingEntry(paper, form: form, samples: []), "w1")
        form.start = "2026.01"; form.end = "2026.03"
        expectNil(G.matchingEntry(paper, form: form, samples: []))
    }

    @Test func skillPoints() {
        let lines: [JSONValue] = [.object(["direction": .string("并发编程"), "text": .string(""), "layers": .array([
            .object(["level": .string("familiar"), "points": .array([.object(["text": .string("JMM"), "source": .string("catalog")]),
                                                                     .object(["text": .string("volatile"), "source": .string("user")])])]),
            .object(["level": .string("proficient"), "points": .array([.object(["text": .string("AQS 原理"), "source": .string("model"), "weak": .bool(true)])])]),
        ])])]
        expectEqual(G.skillLineText(lines[0]), "并发编程：熟悉JMM、volatile，熟练掌握AQS 原理")
        expectEqual(G.addedPoints(lines).map(\.text), ["AQS 原理", "JMM"])
        let next = G.withoutPoint(lines, line: 0, text: "AQS 原理")
        expectEqual(next[0]["layers"]?.items.count, 1)
        expectEqual(next[0].text("text"), "并发编程：熟悉JMM、volatile")
    }

    @Test func honors() {
        func list(_ kind: String, _ lines: [String]) -> JSONValue {
            section("s_\(kind)", kind, blocks: [.object(["node_id": .string("b_\(kind)"), "block_type": .string("bullet_list"),
                "items": .array(lines.enumerated().map { .object(["node_id": .string("i_\(kind)_\($0.offset)"), "runs": .array([run($0.element)])]) })])])
        }
        let form = G.honorsForm(document([list("awards", ["示例奖学金"])]), materials: document([list("certificates", ["英语六级 560"])]),
                                profile: .object(["honors": .array([.string("校一等奖学金")])]), samples: ["s_awards"])
        expectEqual([form.certificates, form.awards], ["英语六级 560", "校一等奖学金"])
        var input = G.HonorsForm(); input.certificates = "英语六级 560\n"; input.awards = "· 校一等奖学金"
        expectEqual(G.honorsOperations(input, templateKinds: ["certificates"]).first?["bullets"], .array([.string("英语六级 560"), .string("校一等奖学金")]))
        expectEqual(G.honorsOperations(input, templateKinds: []).map { $0.text("semantic_kind") }, ["awards", "certificates"])
        #expect(G.honorsOperations(G.HonorsForm(), templateKinds: []).isEmpty)
    }

    @Test func basicInfoAndContacts() {
        var info = G.BasicInfo(); info.name = "林晓"
        #expect(!G.basicInfoReady(info))
        info.email = "lin@example.com"; info.link = "https://github.com/example"
        #expect(G.basicInfoReady(info))
        expectEqual(G.basicInfoOperations(info).first?["contacts"]?.items.map { $0.text("kind") }, ["email", "github"])
        let doc: JSONValue = .object(["identity": .object(["name": text("n", "林晓"), "contacts": .array([
            .object(["contact_kind": .string("phone"), "value": .string("13800000000")]),
            .object(["contact_kind": .string("website"), "value": .string("example.com")])])])])
        expectEqual(G.careerContactChanges(doc, personal: ["phone": "1"]), ["name": "林晓"])
    }
}
