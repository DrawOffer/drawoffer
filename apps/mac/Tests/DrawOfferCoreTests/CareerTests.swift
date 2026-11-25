import Foundation
import Testing
@testable import DrawOfferCore

private func application(_ source: String) throws -> CareerApplication {
    CareerApplication(try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)))
}
@Test func careerChannelsHaveNarrowRouteBoundary() {
    #expect(CareerRequest.allowed(path: "/api/job-applications/12/stages", method: "POST"))
    #expect(CareerRequest.allowed(path: "/api/interview-sessions/12/answer-plan", method: "PUT"))
    for path in ["/api/account/avatar", "/api/job-applications/12/reviews", "/api/job-applications//12", "/api/job-applications/12/", "/api/job-applications/１２", "/api/job-applications?scope=all"] {
        #expect(!CareerRequest.allowed(path: path, method: "GET"))
    }
    #expect(!CareerRequest.allowed(path: "/api/resumes/1/semantic-classification", method: "POST"))
    // Resume management, account page and AI assistant have their own narrow whitelists.
    for (path, method) in [("/api/resumes/1", "DELETE"), ("/api/resumes/1/copy", "POST"), ("/api/resumes/1/share", "PATCH"),
                           ("/api/resume-imports/3", "DELETE"), ("/api/resumes/1/apply-template", "POST"), ("/api/resumes/1/assets", "POST"),
                           ("/api/resumes/1/assets/a.png", "DELETE"), ("/api/account/profile", "GET"), ("/api/account/user-profile", "PUT"),
                           ("/api/agent/sessions", "POST"), ("/api/agent/proposals/abc/confirm", "POST"), ("/api/job-descriptions/2/match", "GET")] {
        #expect(CareerRequest.allowed(path: path, method: method), "\(method) \(path)")
    }
    for (path, method) in [("/api/resumes/1/assets", "GET"), ("/api/resumes/1/apply-template", "GET"), ("/api/account/deletion", "POST"), ("/api/admin/agent-operations", "GET"),
                           ("/api/agent/sessions/1/messages", "POST"), ("/api/resumes/abc", "GET")] {
        #expect(!CareerRequest.allowed(path: path, method: method), "\(method) \(path)")
    }
    #expect(AgentRequest.streams(path: "/api/agent/sessions/1/messages", method: "POST"))
}
@Test func careerProjectionKeepsPendingNullAndDynamicInterviewColumns() throws {
    let pending = try application(#"{"id":"1","phase":"","current_stage":null,"current_stage_type":"screening","applied_at":null}"#)
    #expect(pending.stage == "pending")
    let second = try application(#"{"id":"2","phase":"active","current_stage":{"stage_type":"interview","stage_label":"技术二面"},"current_round_no":2}"#)
    let first = try application(#"{"id":"3","phase":"active","current_stage":{"stage_type":"interview","stage_label":"技术一面"},"current_round_no":1}"#)
    #expect(CareerStage.columns([second, first]).filter { $0.hasPrefix("interview:") } == ["interview:技术一面", "interview:技术二面"])
    #expect(!CareerStage.canAdvance(first, to: "screening"))
    #expect(CareerStage.canAdvance(first, to: "offer"))
    #expect(CareerStage.nextStages(first) == ["interview", "offer"])
    let ai = try application(#"{"id":"5","phase":"active","current_stage_type":"ai_interview","current_stage_label":"AI 面试"}"#)
    #expect(ai.column == "interview:AI 面试")
    #expect(!CareerStage.columns([ai]).contains("ai_interview"))
    #expect(!CareerStage.canAdvance(first, to: ai.column, stage: "ai_interview"))
    let ended = try application(#"{"id":"4","lifecycle_status":"terminated","current_stage_type":"interview"}"#)
    #expect(ended.stage == "ended")
    #expect(!CareerStage.canAdvance(ended, to: "offer"))
}
@Test func careerOrderingUsesUpcomingScheduleAndStableNumericIDs() throws {
    let a = try application(#"{"id":"10","phase":"active","current_stage_type":"interview","created_at":"2030-01-01T00:00:00Z","next_session_start_at":"2030-01-04T00:00:00Z"}"#)
    let b = try application(#"{"id":"2","phase":"active","current_stage_type":"interview","created_at":"2030-01-01T00:00:00Z","next_session_start_at":"2030-01-05T00:00:00Z"}"#)
    #expect(CareerStage.sorted([b,a], earliest:false).map(\.id) == ["10","2"])
    #expect(CareerStage.sorted([a,b], earliest:true).map(\.id) == ["2","10"])
}

@Test func careerCompletedHistoryOnlyUsesCurrentStageAndNewestNonCancelledSession() throws {
    let raw = try application(#"{"id":"1","phase":"active","current_stage":{"id":"8","stage_type":"interview"}}"#)
    let sessions = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"application_id":"1","application_stage_id":"7","status":"completed","start_at":"2030-01-05T00:00:00Z"},{"application_id":"1","application_stage_id":"8","status":"completed","start_at":"2030-01-04T00:00:00Z"},{"application_id":"1","application_stage_id":"8","status":"cancelled","start_at":"2030-01-06T00:00:00Z"}]"#.utf8)).items
    #expect(raw.includingSessions(sessions).completedSchedule == CareerApplication.date("2030-01-04T00:00:00Z"))
    #expect(raw.includingSessions(sessions).statusLabel == "已完成")
}

@Test func companyLogoOnlyAcceptsOwnedVersionedRelativeResource() throws {
    let revision = String(repeating: "a", count: 64)
    let own = try application("{\"company_logo_url\":\"/api/job-descriptions/2/logo?v=\(revision)\"}")
    #expect(own.logoRequest?.path == "/api/job-descriptions/2/logo")
    #expect(own.logoRequest?.revision == revision)
    for value in ["https://example.com/api/job-descriptions/2/logo?v=" + revision, "//example.com/logo", "/api/job-descriptions/2/logo?v=short", "/api/resumes/2?v=" + revision] {
        let raw = JSONValue.object(["company_logo_url": .string(value)])
        #expect(CareerApplication(raw).logoRequest == nil)
    }
}

@Test func v4OfferDecisionEndsApplication() {
    for decision in ["accepted", "declined"] {
        let ended = CareerApplication(.object(["status": .string("closed"), "current_stage_type": .string("offer"), "offer_status": .string(decision)]))
        #expect(ended.stage == "ended")
        #expect(!ended.movable)
    }
    for command in ["close", "archive", "restore"] {
        #expect(CareerRequest.allowed(path: "/api/job-applications/12/" + command, method: "POST"))
        #expect(!CareerRequest.allowed(path: "/api/job-applications/12/" + command, method: "PUT"))
    }
}

@Test func v4NotesPreserveUnrelatedDataAndReplaceOnlySelectedFields() {
    let original = "个人备注\n投递渠道：官网\n未识别字段：保留"
    let merged = CareerNotes.merging(["投递渠道": "内推", "回复截止": "2030-01-02"], into: original)
    #expect(merged.contains("个人备注"))
    #expect(merged.contains("未识别字段：保留"))
    #expect(!merged.contains("官网"))
    #expect(CareerNotes.value("投递渠道", in: merged) == "内推")
}
