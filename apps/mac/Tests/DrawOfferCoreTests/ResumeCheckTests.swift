import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
}

private func run(_ text: String) -> String {
    #"[{"inline_type":"text","text":"\#(text)","marks":[],"href":null,"style":null}]"#
}

private let resume = """
{"sections":[
 {"node_id":"s_work","semantic_kind":"work","title":{"value":"实习经历"},"entries":[
  {"node_id":"e_1","fields":{"organization":{"value":"示例科技"},"role":{"value":"后端实习生"},"start_date":{"value":"2026.06"}},
   "blocks":[{"node_id":"p_1","block_type":"paragraph","runs":\(run("参与订单系统优化"))},
             {"node_id":"l_1","block_type":"bullet_list","items":[{"node_id":"i_1","runs":\(run("负责接口开发"))}]}]}]},
 {"node_id":"s_skill","semantic_kind":"skills","title":{"value":"专业技能"},"blocks":[{"node_id":"p_2","block_type":"paragraph","runs":\(run("熟悉 Java"))}]},
 {"node_id":"s_award","semantic_kind":"awards","title":{"value":"荣誉奖项"},"blocks":[{"node_id":"p_3","block_type":"paragraph","runs":\(run("一等奖学金"))}]}]}
"""

private func label(_ section: JSONValue) -> String { ResumeDocument.value(section["title"]) }

@Test func checkUnitsSplitEntriesAndSkipUncheckedSections() throws {
    let units = ResumeCheck.units(try json(resume), label: label)
    #expect(units.map(\.id) == ["e_1", "s_skill"])
    #expect(units[0].heading == "示例科技")
    #expect(units[0].headingField == "organization")
    #expect(units[0].meta == ["后端实习生", "2026.06"])
    #expect(units[0].lines.map(\.id) == ["p_1", "i_1"])
    #expect(units[1].kind == .skills)
}

@Test func checkWritesBackOnlyWhenTheLineIsUnchanged() throws {
    let document = try json(resume)
    guard case .success(let next) = ResumeCheck.replaceLine(document, lineID: "p_1", before: "参与订单系统优化", with: "改好的一句") else {
        Issue.record("replace failed"); return
    }
    #expect(ResumeCheck.lineText(next, lineID: "p_1") == "改好的一句")
    #expect(ResumeCheck.replaceLine(next, lineID: "p_1", before: "参与订单系统优化", with: "再改") == .failure(.conflict))
    #expect(ResumeCheck.replaceLine(next, lineID: "nope", before: "", with: "x") == .failure(.missing))
}

@Test func resumeCheckRouteIsClosedAfterWebRemovedIt() {
    #expect(!ResumeRequest.allowed(path: "/api/resumes/12/review:check", method: "POST"))
    #expect(ResumeRequest.allowed(path: "/api/resumes/12/section-review:rewrite", method: "POST"))
}
