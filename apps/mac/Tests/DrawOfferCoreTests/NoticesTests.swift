import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }

@Test func inboxMessageActionsFollowWeb() throws {
    func message(_ category: String, _ link: String) throws -> InboxMessage {
        InboxMessage(json: try json(#"{"id":"n1","category":"\#(category)","title":"t","body":"b","link":"\#(link)","read":false,"createdAt":"2026-11-17T10:20:00Z"}"#))
    }
    let credits = try message("feedback", "/account#credits")
    #expect(credits.categoryLabel == "问题反馈" && credits.action == "查看积分" && credits.opensCredits && credits.tone == "blue")
    let duplicate = try message("feedback", "")
    #expect(duplicate.action == nil && !duplicate.opensCredits)
    #expect(try message("task", "/career/reviews?session=1&application=2").action == "查看复盘")
    #expect(try message("task", "/mock-interviews/9/report").action == "查看报告")
    #expect(try message("task", "/mock-interviews/9").action == "去看看")
    #expect(try message("interview", "/interviews").action == "去准备")
    #expect(try message("interview", "/interviews").tone == "orange")
    #expect(try message("peak", "//evil.example").safeLink == nil)
    #expect(try message("task", "/x").createdAt != nil)
}

@Test func feedbackDraftReadinessAndBody() {
    var draft = FeedbackDraft()
    #expect(!draft.ready)
    draft.feature = "简历编辑器"; draft.title = "  导出 PDF 时第二页是空白的 "; draft.content = "1. 导出\n2. 看第二页"
    #expect(draft.ready)
    draft.occurred = .today; draft.contact = "someone@example.com"; draft.shots = ["data:image/png;base64,AAAA"]
    let signedIn = draft.body(signedIn: true, clientVersion: "mac-1.0")
    #expect(signedIn.text("title") == "导出 PDF 时第二页是空白的")
    #expect(signedIn.text("pageName") == "简历编辑器" && signedIn.text("pagePath") == "")
    #expect(signedIn.text("occurred") == "today" && signedIn.text("kind") == "bug" && signedIn.text("client") == "web")
    #expect(signedIn.text("contact") == "", "登录时不带联系方式")
    #expect(signedIn["screenshots"]?.items.count == 1)
    #expect(draft.body(signedIn: false, clientVersion: "mac-1.0").text("contact") == "someone@example.com")
    draft.kind = .idea
    #expect(draft.placeholder.hasPrefix("希望多一个"))
    #expect(FeedbackDraft().body(signedIn: true, clientVersion: "").text("occurred") == "")
}

@Test func feedbackErrorsAreReadable() {
    #expect(FeedbackDraft.errorText(APIError.server(status: 429, code: "FEEDBACK_RATE_LIMITED")).hasPrefix("今天提交得有点多了"))
    #expect(FeedbackDraft.errorText(APIError.server(status: 413, code: "IMAGE_TOO_LARGE")) == "截图太大了，换一张小一点的")
    #expect(FeedbackDraft.errorText(APIError.server(status: 403, code: "DESKTOP_ROUTE_FORBIDDEN")).hasPrefix("桌面端暂时还不能提交反馈"))
    #expect(FeedbackDraft.errorText(APIError.invalidResponse) == "提交失败，请稍后再试")
    #expect(FeedbackDraft.footnote(signedIn: true, nickname: "林知夏").hasPrefix("以 林知夏 的账号提交"))
}

@Test func communityGroupsKeepHTTPLinksOnly() throws {
    let both = CommunityGroups(json: try json(#"{"qq":"https://qm.example.com/q/abc","wechat":"http://wx.example.com/g"}"#))
    #expect(both.both && both.current("wechat")?.key == "wechat" && both.current("qq")?.key == "qq")
    let wechatOnly = CommunityGroups(json: try json(#"{"qq":"javascript:alert(1)","wechat":"https://wx.example.com/g"}"#))
    #expect(wechatOnly.qq == nil && wechatOnly.current("qq")?.key == "wechat")
    #expect(CommunityGroups(json: try json(#"{"qq":null,"wechat":null}"#)).isEmpty)
}

@Test func feedbackRoutesAndCache() {
    #expect(CareerRequest.allowed(path: "/api/feedback", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/feedback", method: "GET"))
    #expect(CareerRequest.allowed(path: "/api/community-groups", method: "GET"))
    #expect(!ReadCache.affected(byWriteTo: "/api/feedback", key: "/api/job-applications"))
    #expect(ReadCache.lifetime(path: "/api/community-groups", query: [:]) == nil)
}

@Test func announcementMetaLine() throws {
    let item = Announcement(json: try json(#"{"id":"a1","level":"important","category":"service_notice","title":"维护","body":"x","publishedAt":"2026-11-17T02:00:00Z","read":false}"#))
    #expect(item.metaText == "服务通知 · 11 月 17 日")
    let undated = Announcement(json: try json(#"{"id":"a2","level":"normal","category":"product_update","title":"t","body":"x","read":true}"#))
    #expect(undated.metaText == "产品更新")
}
