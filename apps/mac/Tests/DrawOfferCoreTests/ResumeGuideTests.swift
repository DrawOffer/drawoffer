import DrawOfferCore
import Foundation
import Testing

/// 新建简历引导（Web `guide/guideModel.ts` + `GuideFlow.tsx`）：步骤对应、预填与写入要和 Web 一致。
struct ResumeGuideTests {
    typealias G = ResumeGuideModel

    func text(_ id: String, _ value: String) -> JSONValue { .object(["node_id": .string(id), "source_refs": .array([]), "value": .string(value)]) }
    func run(_ value: String) -> JSONValue { .object(["inline_type": .string("text"), "text": .string(value), "marks": .array([])]) }
    func paragraph(_ id: String, _ line: String) -> JSONValue { .object(["node_id": .string(id), "block_type": .string("paragraph"), "runs": .array([run(line)])]) }
    func bullets(_ id: String, _ lines: [String]) -> JSONValue {
        .object(["node_id": .string(id), "block_type": .string("bullet_list"),
                 "items": .array(lines.enumerated().map { .object(["node_id": .string("\(id)_\($0.offset)"), "runs": .array([run($0.element)])]) })])
    }
    func entry(_ id: String, fields: [String: String], blocks: [JSONValue] = []) -> JSONValue {
        .object(["node_id": .string(id), "fields": .object(fields.mapValues { text(id + "_f", $0) }), "blocks": .array(blocks)])
    }
    func section(_ id: String, _ kind: String, title: String, entries: [JSONValue] = [], blocks: [JSONValue] = []) -> JSONValue {
        .object(["node_id": .string(id), "semantic_kind": .string(kind), "title": text(id + "_t", title), "entries": .array(entries), "blocks": .array(blocks)])
    }
    func document(name: String = "林小满", contacts: [(String, String)] = [], _ sections: [JSONValue]) -> JSONValue {
        .object(["identity": .object(["node_id": .string("idn"), "name": text("idn_name", name),
                                      "contacts": .array(contacts.map { .object(["node_id": .string("c_" + $0.0), "contact_kind": .string($0.0), "value": .string($0.1)]) })]),
                 "sections": .array(sections)])
    }
    func guide(_ current: String, written: [String] = []) -> JSONValue {
        let steps = ["job_profile", "materials", "basics", "education", "skills", "experience", "wrap_up"]
        return .object(["current_step": .string(current), "status": .string("active"), "version": .number(3),
                        "steps": .object(Dictionary(uniqueKeysWithValues: steps.map { ($0, JSONValue.object(["status": .string(written.contains($0) ? "written" : "pending")])) }))])
    }

    @Test func mapsServerStepsToSixScreensAndWalksThere() {
        #expect(G.step(current: "education", finishing: false) == .basics)
        #expect(G.step(current: "wrap_up", finishing: false) == .skills)
        #expect(G.step(current: "wrap_up", finishing: true) == .finish)
        let started = guide("experience", written: ["job_profile", "materials", "basics"])
        #expect(G.reached(.materials, current: .experience, guide: started, seenFinish: false))
        #expect(!G.reached(.skills, current: .experience, guide: started, seenFinish: false))
        #expect(G.reached(.finish, current: .experience, guide: started, seenFinish: true))
        #expect(G.reachAction(guide("job_profile"), target: "materials")! == ("confirm_profile", nil))
        #expect(G.reachAction(started, target: "basics")! == ("goto_step", "basics"))
        #expect(G.reachAction(started, target: "skills")! == ("next", nil))
        #expect(G.reachAction(started, target: "experience") == nil)
        #expect(G.untouched(guide("job_profile")))
        #expect(!G.untouched(started) && G.resuming(started))
        #expect(G.failureText("CREDIT_INSUFFICIENT") == "积分不够了，充值后再试。")
        #expect(G.failureText("EXPERIENCE_COMPOSE_INVALID") == "这次没写好，多说一两句再试。")
    }

    @Test func basicInfoSkipsSamplesAndClearsEmptiedContacts() throws {
        let paper = document(contacts: [("phone", "138 0000 0000"), ("email", "xiaoman@example.com")], [])
        let info = G.basicInfo(paper, samples: ["c_email"])
        #expect(info == G.BasicInfo(name: "林小满", phone: "138 0000 0000", email: "", link: ""))
        var edited = info; edited.phone = ""; edited.link = "https://github.com/example"
        let op = try #require(G.basicInfoOperations(edited, own: info).first)
        #expect(op.text("name") == "林小满")
        #expect(op["contacts"]?.items.map { $0.text("kind") } == ["github"])
        #expect(op["clear_contacts"]?.items.compactMap(\.stringValue) == ["phone"])
        #expect(G.basicInfoOperations(G.BasicInfo()).isEmpty)
    }

    @Test func educationsReadOldHeadingsAndWriteFields() throws {
        let old = entry("e_old", fields: ["organization": "某某大学"], blocks: [paragraph("p1", "2022.09—2026.06｜统计学 · 本科；主修：回归分析、数据挖掘"), paragraph("p2", "GPA 3.6 / 4.0")])
        let paper = document([section("s_edu", "education", title: "教育经历", entries: [old])])
        let forms = G.educations(paper, profile: nil, samples: [])
        #expect(forms.count == 1)
        #expect(forms[0].school == "某某大学" && forms[0].start == "2022.09" && forms[0].end == "2026.06")
        #expect(forms[0].major == "统计学" && forms[0].degree == "本科")
        #expect(forms[0].courses == "回归分析、数据挖掘")
        let empty = G.educations(document([]), profile: .object(["school": .string("某某大学"), "education_level": .string("master"), "graduation_year": .number(2029)]), samples: [])
        #expect(empty[0].school == "某某大学" && empty[0].degree == "硕士" && empty[0].end == "2029.06" && empty[0].entryID == nil)

        var edited = forms
        edited[0].major = "应用统计"
        edited.append(G.EducationForm(school: "另一所大学", degree: "硕士", start: "2026.09", end: "2029.06"))
        let operations = G.educationsOperations(edited, removed: [], title: "教育背景", document: paper)
        #expect(operations.map { $0.text("op") } == ["fill_entry", "write_section"])
        #expect(operations[0]["entry"]?["fields"]?.text("major") == "应用统计")
        #expect(operations[1].text("title") == "教育背景")
        #expect(operations[1]["entries"]?.items.first?["fields"]?.text("degree") == "硕士")
        edited[0].school = ""
        #expect(G.educationsOperations(edited, removed: [], title: nil, document: paper).last?.text("op") == "remove")
        #expect(G.educationMissingSchool([G.EducationForm(major: "统计学")]) == 0)
        #expect(G.educationMissingSchool([G.EducationForm(degree: "本科", end: "2026.06")]) == nil)
        #expect(G.educationLabel(0) == "教育" && G.educationLabel(1) == "第二段教育")
    }

    @Test func experienceCategoriesFollowStageAndTemplateTitles() {
        let sample = document([section("t_p", "project", title: "项目实践", entries: [entry("t_e", fields: ["name": "示例项目"], blocks: [paragraph("t_l", "技术环境：Python")])])])
        let graduate = G.categories(stage: .graduate, sample: sample)
        #expect(graduate.map(\.key) == ["project", "intern", "contest", "campus", "parttime", "portfolio"])
        #expect(graduate[0].title == "项目实践")
        #expect(graduate[0].lines == G.EntryLines(tech: "技术环境", intro: "项目介绍"))
        #expect(G.categories(stage: .worked, sample: nil).first?.key == "work")
    }

    @Test func segmentsSplitDescriptionLinesAndComposeBody() {
        let project = entry("e_p", fields: ["name": "校园外卖订单数据分析", "role": "课程设计", "start_date": "2025.03", "end_date": "2025.06"],
                            blocks: [paragraph("l1", "技术架构：Python、Excel"), bullets("b", ["清洗订单数据", "写分析报告"])])
        let paper = document([section("s_p", "project", title: "项目经历", entries: [project]), section("s_c", "activity", title: "竞赛经历", entries: [entry("e_c", fields: ["organization": "数学建模竞赛"])])])
        let all = G.categories(stage: .graduate, sample: nil)
        let category = all[0]
        #expect(G.categoryEntries(paper, category, all: all, samples: []).map { $0.text("node_id") } == ["e_p"])
        #expect(G.categoryEntries(paper, all.first { $0.key == "contest" }!, all: all, samples: []).map { $0.text("node_id") } == ["e_c"])
        let segment = G.segment(category, entry: project)
        #expect(segment.name == "校园外卖订单数据分析" && segment.role == "课程设计")
        #expect(segment.tech == "Python、Excel" && segment.techLabel == "技术架构")
        #expect(segment.did == "清洗订单数据\n写分析报告")
        #expect(G.entryTime(project) == "2025.03 – 2025.06")
        var edited = segment; edited.did = "清洗订单数据\n\n写分析报告\n"
        let body = G.experienceBody(category, segment: edited, document: paper)
        #expect(body.text("did") == "清洗订单数据\n写分析报告")
        #expect(body["fields"]?.text("name") == "校园外卖订单数据分析")
        #expect(body["lines"]?.items.first?.text("label") == "技术架构")
        #expect(body["title"] == .null && body["own_section"] == .bool(false))
        #expect(segment.same(edited, keys: [\.name, \.role]))
        #expect(!segment.same(edited))
    }

    @Test func putsADeletedEntryBackWhereItWas() {
        let a = entry("a", fields: ["name": "甲"]), b = entry("b", fields: ["name": "乙"]), c = entry("c", fields: ["name": "丙"])
        let before = document([section("s1", "project", title: "项目经历", entries: [a, b, c]), section("s2", "activity", title: "校园经历", entries: [entry("d", fields: ["organization": "丁"])])])
        let removedB = document([section("s1", "project", title: "项目经历", entries: [a, c]), section("s2", "activity", title: "校园经历", entries: [entry("d", fields: ["organization": "丁"])])])
        let back = G.withEntryBack(removedB, before: before, entryID: "b")
        #expect(back["sections"]?.items.first?["entries"]?.items.map { $0.text("node_id") } == ["a", "b", "c"])
        let removedSection = document([section("s2", "activity", title: "校园经历", entries: [entry("d", fields: ["organization": "丁"])])])
        let restored = G.withEntryBack(removedSection, before: before, entryID: "a")
        #expect(restored["sections"]?.items.map { $0.text("node_id") } == ["s1", "s2"])
        #expect(restored["sections"]?.items.first?["entries"]?.items.map { $0.text("node_id") } == ["a"])
    }

    @Test func readsSkillsOnPaperAndTechTerms() {
        func skills(_ line: String) -> JSONValue { document([section("s_k", "skills", title: "专业技能", blocks: [paragraph("k", line)])]) }
        #expect(G.skillsOnPaper(skills("熟练：Java、MySQL；了解：Kafka")).map { "\($0.name)=\($0.level ?? "-")" } == ["Java=proficient", "MySQL=proficient", "Kafka=basic"])
        #expect(G.skillsOnPaper(skills("Spring、Spring Boot：熟悉依赖注入")).map(\.name) == ["Spring", "Spring Boot"])
        #expect(G.skillsOnPaper(skills("编程语言：Java、Go")).map(\.name) == ["Java", "Go"])
        let paper = document([section("s_p", "project", title: "项目经历", entries: [entry("e", fields: ["name": "分析"], blocks: [paragraph("x", "用 Python 和 Tableau 做图，QPS 不高")])])])
        #expect(G.techTermsOnPaper(paper, samples: []) == ["Python", "Tableau"])
        #expect(G.addingSkills(["Python"], "python、SQL，Excel") == ["Python", "SQL", "Excel"])
        #expect(G.nameCore("某某科技有限公司") == "某某")
    }

    @Test func guideRoutesAreAllowedForDesktop() {
        for action in ["writes", "portrait:fill", "materials:compose", "skills:compose", "experience:compose", "profile:compose", "answer:extract"] {
            #expect(ResumeRequest.allowed(path: "/api/resumes/9401/guide/\(action)", method: "POST"))
        }
        #expect(ResumeRequest.allowed(path: "/api/resumes/9401/guide", method: "PATCH"))
        #expect(!ResumeRequest.allowed(path: "/api/resumes/9401/guide/answer:extract", method: "GET"))
    }
}

@Test func guidePortraitSummaryCountsWhatCanGoOnPaper() throws {
    func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    let career = try json(#"{"personal":{"name":"林小满"},"experience":{"sections":[{"kind":"education","title":"教育","entries":[{"id":"1"}],"lines":[]},{"kind":"project","title":"项目","entries":[{"id":"2"},{"id":"3"}],"lines":[]},{"kind":"other","title":"网申基础资料","entries":[{"id":"4"}],"lines":[]}],"records":{"competition":[{"values":{"name":"数学建模"}}]},"skills":[{"name":"SQL"}]}}"#)
    let summary = try #require(ResumeGuideModel.portrait(career: career, profile: nil))
    #expect(summary.text == "基本信息、1 段教育、3 段经历、1 项技能")
    #expect(ResumeGuideModel.portrait(career: try json(#"{"personal":{},"experience":{"sections":[],"records":{},"skills":[]}}"#), profile: nil) == nil)
    #expect(ResumeGuideModel.portrait(career: nil, profile: nil) == nil)
}
