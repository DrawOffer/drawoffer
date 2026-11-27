import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }

@Test func agentRatingAndBranchRoutesAreNarrow() {
    #expect(AgentRequest.allowed(path: "/api/agent/sessions/s1/messages/12/rating", method: "PUT"))
    #expect(AgentRequest.allowed(path: "/api/agent/sessions/s1/messages/12:switch", method: "POST"))
    #expect(!AgentRequest.streams(path: "/api/agent/sessions/s1/messages/12:switch", method: "POST"))
    #expect(AgentRequest.streams(path: "/api/agent/sessions/s1/messages/12:edit", method: "POST"))
    for (path, method) in [("/api/agent/sessions/s1/messages/12/rating", "POST"), ("/api/agent/sessions/s1/messages/x/rating", "PUT"),
                           ("/api/agent/sessions/s1/messages/12:delete", "POST"), ("/api/agent/sessions/s1/messages/12:switch", "GET")] {
        #expect(!AgentRequest.allowed(path: path, method: method), "\(method) \(path)")
    }
    #expect(!ReadCache.affected(byWriteTo: "/api/agent/sessions/s1/messages/12/rating", key: "/api/resumes"))
    #expect(ReadCache.affected(byWriteTo: "/api/agent/proposals/p1/confirm", key: "/api/resumes"))
}

@Test func agentRatingTogglesReasonsAndKeepsDownChoice() throws {
    #expect(AgentRating(try json(#"{"rating":"down","reasons":["wrong","bogus"],"note":"太泛"}"#)) == AgentRating(up: false, reasons: ["wrong"], note: "太泛"))
    #expect(AgentRating(try json(#"{"rating":"meh"}"#)) == nil)
    let down = AgentRating.down(from: AgentRating(up: true))
    #expect(down == AgentRating(up: false))
    let picked = down.toggling("too_long").toggling("wrong")
    #expect(picked.reasons == ["too_long", "wrong"])
    #expect(picked.toggling("too_long").reasons == ["wrong"])
    // 已经是没用时再点没用不清空原因
    #expect(AgentRating.down(from: picked) == picked)
    #expect(picked.withNote("  想要更具体的例子 ").json == (try json(#"{"rating":"down","reasons":["too_long","wrong"],"note":"想要更具体的例子"}"#)))
}

@Test func agentBranchEditsAnyPlainQuestionAndRegeneratesLastReply() throws {
    let messages = try json(#"""
    [{"sequence_no":1,"role":"user","content":"问一"},{"sequence_no":2,"role":"assistant","content":"答一"},
     {"sequence_no":3,"role":"assistant","message_type":"clarification","content":""},
     {"sequence_no":4,"role":"user","content":"选 A","reply_to_sequence_no":3},
     {"sequence_no":5,"role":"user","content":"带附件","attachments":[{"file_name":"a.png"}]},
     {"sequence_no":6,"role":"user","content":"问二","versions":{"index":2,"total":3,"sequence_nos":[4,6,9]}},
     {"sequence_no":7,"role":"assistant","content":"答二"}]
    """#).items
    #expect(AgentBranch.editable(messages[0], in: messages, busy: false))
    #expect(!AgentBranch.editable(messages[0], in: messages, busy: true))
    #expect(!AgentBranch.editable(messages[3], in: messages, busy: false))
    #expect(!AgentBranch.editable(messages[4], in: messages, busy: false))
    #expect(AgentBranch.regenerable(messages, busy: false).map { [$0.reply, $0.question] } == [7, 6])
    #expect(AgentBranch.regenerable(Array(messages.prefix(6)), busy: false) == nil)
    #expect(AgentBranch.ratable(messages[6]) && !AgentBranch.ratable(messages[2]))
    let versions = try #require(AgentVersions(messages[5]["versions"]))
    #expect(versions.label == "2/3" && versions.previous == 4 && versions.next == 9)
    #expect(AgentVersions(try json(#"{"index":1,"total":1,"sequence_nos":[4]}"#)) == nil)
}

@Test func agentQueueInsertsOneAtATimeAndReturnsRejected() {
    var items: [AgentQueuedMessage] = []
    for index in 0..<AgentQueue.maximum { items = AgentQueue.adding(items, .init(id: "q\(index)", content: "第\(index)条", contexts: []))! }
    #expect(AgentQueue.adding(items, .init(id: "x", content: "多", contexts: [])) == nil)
    #expect(AgentQueue.canInsert(items, running: true, runID: "r1", compacting: false))
    #expect(!AgentQueue.canInsert(items, running: true, runID: nil, compacting: false))
    items = AgentQueue.inserting(items, id: "q1", runID: "r1", key: "k1")
    #expect(items[1].caption(running: true) == "已插入，AI 做完这一步就接上")
    #expect(!AgentQueue.canInsert(items, running: true, runID: "r1", compacting: false))
    #expect(AgentQueue.next(items)?.id == "q0")
    let returned = AgentQueue.returned(items, key: "k1", error: "没有插入成功，可以再试一次。")
    #expect(returned[1].state == .queued && returned[1].caption(running: true) == "没有插入成功，可以再试一次。")
    #expect(AgentQueue.accepted(items, key: "k1").map(\.id) == ["q0", "q2", "q3", "q4"])
    #expect(items[0].caption(running: false) == "待发送")
}

@Test func agentReplyTextHidesMarkersOutsideCode() {
    #expect(AgentReplyText.clean("项目经历 [[linkresume-block:[b12]]] 写得不错[M3]。") == "项目经历 写得不错。")
    #expect(AgentReplyText.clean("看这里 [[linkresume-block:[a1], [a2]]]") == "看这里")
    #expect(AgentReplyText.clean("```\n[[linkresume-block:[a1]]] [M1]\n```") == "```\n[[linkresume-block:[a1]]] [M1]\n```")
    #expect(AgentReplyText.clean("正在改 [[linkres", streaming: true) == "正在改")
    #expect(AgentReplyText.clean("引用 [M1", streaming: true) == "引用")
    #expect(AgentReplyText.stabilizeStreaming("先看[这一场](drawoffer:mock/") == "先看这一场")
    #expect(AgentReplyText.stabilizeStreaming("这是 **重点") == "这是 **重点**")
    #expect(AgentReplyText.stabilizeStreaming("结尾 **") == "结尾 ")
    #expect(AgentReplyText.stabilizeStreaming("段落\n```markdown") == "段落")
    #expect(AgentReplyText.stabilizeStreaming("列表 *") == "列表 ")
}

@Test func agentCardsDedupeAcrossCardsAndBorrowLogo() throws {
    let cards = try json(#"""
    [{"id":"a","type":"objects","items":[{"kind":"pool_job","id":"7","title":"后端"},{"kind":"application","id":"3","title":"投递"}]},
     {"id":"b","type":"jobs","items":[{"id":"7","title":"后端","company":"青禾科技","logo_url":"/logo.png"},{"id":"8","title":"前端"}]},
     {"id":"c","type":"confirm"}]
    """#).items
    let result = AgentCards.dedupe(cards)
    #expect(result.map { $0.text("id") } == ["a", "b", "c"])
    #expect(result[0]["items"]?.items.first?.text("logo_url") == "/logo.png")
    #expect(result[1]["items"]?.items.map { $0.text("id") } == ["8"])
}

@Test func jobReadinessFollowsProfileMatchRules() throws {
    let empty = JobReadiness.missing(profile: try json(#"{"experience":null}"#), intent: try json(#"{"target_role":" "}"#))
    #expect(empty.map(\.key) == ["target_role", "education", "skills"])
    #expect(empty.map(\.label) == ["目标岗位", "教育经历", "技能"])
    let profile = try json(#"""
    {"experience":{"sections":[{"kind":"education","entries":[{"id":"e1","fields":{"学校":"江南理工大学"},"description":""}]},
                               {"kind":"project","entries":[{"id":"p1","fields":{},"description":"做了一个检索服务"}]}],"skills":[]}}
    """#)
    #expect(JobReadiness.missing(profile: profile, intent: try json(#"{"target_role":"后端开发工程师"}"#)).isEmpty)
    #expect(JobReadiness.missing(profile: profile, intent: nil).map(\.key) == ["target_role"])
}

@Test func modelMenuPutsFreeFirstThenMemberThenLocked() throws {
    let models = try json(#"[{"id":"m1","available":true},{"id":"f1","isFreeTier":true},{"id":"x1","available":false},{"id":"m2"}]"#).items
    #expect(AgentModelSections.split(models).map { $0.map { $0.text("id") } } == [["f1"], ["m1", "m2"], ["x1"]])
}
