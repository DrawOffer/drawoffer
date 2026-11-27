import Foundation
import Testing
@testable import DrawOfferCore

private func metric(_ id: String, text: String = "负责虚构示例平台的接口设计与联调", lines: Double = 2, fill: Double = 0.123456,
                    severity: String = "widow", extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = [
        "node_id": .string(id), "section": .string("项目经历"), "section_kind": .string("experience"), "text": .string(text),
        "is_list_item": .bool(true), "is_entry_head": .bool(false), "is_in_resume_row": .bool(false), "has_bold": .bool(false),
        "line_count": .number(lines), "fill_ratio": .number(fill), "last_line_text": .string("与联调"), "severity": .string(severity),
    ]
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

@Test func smartLayoutRequestFollowsWebTruncation() throws {
    let long = String(repeating: "字", count: 2100)
    let body = try #require(ResumeSmartLayout.requestBody(blocks: [
        metric("node_a"),
        metric("node_b", text: long, lines: 80, fill: 1.4, severity: "weird", extra: [
            "section": .string(String(repeating: "段", count: 70)), "section_kind": .string(""), "last_line_text": .string(String(repeating: "尾", count: 250)),
        ]),
        metric("", text: "没有 ID 的段落"),
        metric("node_c", text: "   "),
    ]))
    #expect(body["mode"] == .string("all"))
    let blocks = body["blocks"]?.items ?? []
    #expect(blocks.map { $0.text("node_id") } == ["node_a", "node_b"])
    #expect(blocks[0]["fill_ratio"] == .number(0.123))
    #expect(blocks[0]["is_list_item"] == .bool(true))
    #expect(blocks[0]["severity"] == .string("widow"))
    #expect(blocks[1].text("text").count == 2000)
    #expect(blocks[1].text("section").count == 60)
    #expect(blocks[1].text("section_kind") == "other")
    #expect(blocks[1].text("last_line_text").count == 200)
    #expect(blocks[1]["line_count"] == .number(50))
    #expect(blocks[1]["fill_ratio"] == .number(1))
    #expect(blocks[1]["severity"] == .string("ok"))
}

@Test func smartLayoutRequestCapsBlocksAndSkipsEmptyPaper() {
    let many = (0..<130).map { metric("node_\($0)") }
    #expect(ResumeSmartLayout.requestBody(blocks: many)?["blocks"]?.items.count == 120)
    #expect(ResumeSmartLayout.requestBody(blocks: []) == nil)
    #expect(ResumeSmartLayout.requestBody(blocks: [metric("node_x", text: "\n ")]) == nil)
}

@Test func smartLayoutOutcomeMatchesWebMessages() {
    let fewer = ResumeSmartLayout.outcome(total: 3, applied: 2, summary: "收了两行", pagesBefore: 2, pagesAfter: 1, smartOnePage: false, undoable: true)
    #expect(fewer == .init(message: "排好了，压到 1 页。", undoable: true, seconds: 8))
    let same = ResumeSmartLayout.outcome(total: 3, applied: 2, summary: "", pagesBefore: 1, pagesAfter: 1, smartOnePage: false, undoable: false)
    #expect(same.message == "排好了，改了 2 处。")
    #expect(!same.undoable)
    // 智能一页恒按 1 页，不会说“压到”
    #expect(ResumeSmartLayout.outcome(total: 1, applied: 1, summary: "", pagesBefore: 2, pagesAfter: 1, smartOnePage: true, undoable: true).message == "排好了，改了 1 处。")
    let nothing = ResumeSmartLayout.outcome(total: 0, applied: 0, summary: " 排版已经很整齐。 ", pagesBefore: 1, pagesAfter: 1, smartOnePage: false, undoable: true)
    #expect(nothing == .init(message: "排版已经很整齐。", undoable: false, seconds: 4))
    #expect(ResumeSmartLayout.outcome(total: 2, applied: 0, summary: "", pagesBefore: 1, pagesAfter: 1, smartOnePage: false, undoable: false).message
        == "现在的排版已经挺整齐，没有要动的。")
}

@Test func smartLayoutErrorsAndRoute() {
    #expect(ResumeSmartLayout.errorMessage(APIError.server(status: 402, code: "CREDIT_INSUFFICIENT")) == "积分不够了，充值后再试。")
    #expect(ResumeSmartLayout.errorMessage(APIError.server(status: 403, code: "PAID_CREDIT_REQUIRED")) == "积分不够了，充值后再试。")
    #expect(ResumeSmartLayout.errorMessage(APIError.server(status: 502, code: "LLM_UNAVAILABLE")) == "小绘没能生成排版建议，检查网络后再试。")
    #expect(ResumeSmartLayout.errorMessage(APIError.server(status: 403, code: "DESKTOP_ROUTE_FORBIDDEN")).contains("尚未开放"))
    #expect(ResumeRequest.allowed(path: "/api/resumes/12/review:layout", method: "POST"))
    #expect(!ResumeRequest.allowed(path: "/api/resumes/12/review:layout", method: "GET"))
}

@Test func orbSaysLayoutBusyWithStopOnly() {
    let busy = ResumeOrb.dialogue(unitID: "e_1", unitLabel: "项目经历 · 虚构平台", layoutBusy: true)
    #expect(busy.say == "正在排版，纸面照常能改。")
    #expect(busy.actions == [.layoutCancel])
    #expect(busy.note == nil)
    #expect(!busy.input)
    #expect(ResumeOrb.dialogue(unitID: nil, unitLabel: nil).input)
}
