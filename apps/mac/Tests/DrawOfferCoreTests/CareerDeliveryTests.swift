import Foundation
import Testing
@testable import DrawOfferCore

@Test func recordAppliedPresetFollowsBoardColumn() {
    #expect(CareerRecordApplied.preset(stage: "screening", label: "筛选中").step == .screening)
    #expect(CareerRecordApplied.preset(stage: "assessment", label: "测评").step == .written("assessment"))
    let interview = CareerRecordApplied.preset(stage: "interview", label: "二面")
    #expect(interview.step == .interview && interview.interviewLabel == "二面")
    #expect(CareerRecordApplied.preset(stage: "interview", label: "面试中").interviewLabel == "一面")
    #expect(CareerRecordApplied.preset(stage: "hr", label: "").interviewLabel == "HR 面")
}

@Test func recordAppliedCopyNamesTheTargetStep() {
    #expect(CareerRecordApplied.target(.screening, interviewLabel: "一面") == nil)
    #expect(CareerRecordApplied.target(.written("ai_interview"), interviewLabel: "一面") == "AI 面试")
    #expect(CareerRecordApplied.submitLabel("笔试") == "记录投递并进入笔试")
    #expect(CareerRecordApplied.submitLabel(nil) == "记录投递")
    #expect(CareerRecordApplied.footHint(nil) == "之后的排期在详情页「安排时间」")
    #expect(CareerRecordApplied.steps.map(\.1) == ["筛选中", "测评", "笔试", "AI 面试", "面试"])
}

@Test func recordAppliedRequiresResumeOnlyWhenThereIsOne() {
    #expect(CareerRecordApplied.resumeMissing(selected: nil, resumeCount: 2))
    #expect(CareerRecordApplied.resumeMissing(selected: "", resumeCount: 1))
    #expect(!CareerRecordApplied.resumeMissing(selected: "r1", resumeCount: 2))
    #expect(!CareerRecordApplied.resumeMissing(selected: nil, resumeCount: 0))
}

@Test func recordAppliedBodyWritesNoonBeijingAndInterviewRound() throws {
    let day = try #require(ISO8601DateFormatter().date(from: "2030-10-08T17:30:00Z")) // 北京 10 月 9 日凌晨
    let body = CareerRecordApplied.stageBody(step: .interview, interviewLabel: "二面", roundNo: 2, appliedOn: day, channel: " 牛客 ", resumeID: "r1")
    #expect(body["stage_type"] == .string("interview"))
    #expect(body["stage_label"] == .string("二面"))
    #expect(body["interview_round_no"] == .number(2))
    #expect(body["applied_at"] == .string("2030-10-09T04:00:00Z"))
    #expect(body["applied_channel"] == .string("牛客"))
    #expect(body["resume_id"] == .string("r1"))
    let bare = CareerRecordApplied.stageBody(step: .written("written_test"), interviewLabel: "一面", roundNo: nil, appliedOn: nil, channel: "", resumeID: nil)
    #expect(bare == ["stage_type": .string("written_test")])
}

@Test func endClockStepsQuarterHoursFromStart() {
    let options = CareerTimeSpan.options(startMinute: 23 * 60 + 30, current: 60)
    #expect(options.count == 32)
    #expect(options.first == .init(minutes: 15, clock: "23:45", span: "15 分钟"))
    #expect(options[1].clock == "00:00")
    #expect(options.last?.minutes == 480)
    let odd = CareerTimeSpan.options(startMinute: nil, current: 50)
    #expect(odd.count == 33 && odd[3] == .init(minutes: 50, clock: "10:50", span: "50 分钟"))
    #expect(CareerTimeSpan.label(90) == "1.5 小时")
    #expect(CareerTimeSpan.label(75) == "1.25 小时")
    #expect(CareerTimeSpan.label(120) == "2 小时")
}

@Test func dropOnRecordStepKeepsOnlyRecordings() {
    let names = ["一面.m4a", "简历.PDF", "录屏.MOV"]
    let record = CareerDropRule.accept(names, figure: .recordEmpty)
    #expect(record.kept == [0, 2] && record.notice == CareerDropRule.recordingOnlyNotice)
    #expect(CareerDropRule.accept(["a.mp3"], figure: .recordFailed).notice == nil)
    let other = CareerDropRule.accept(names, figure: .questions)
    #expect(other.kept == [0, 1, 2] && other.notice == nil)
    #expect(!CareerDropRule.isMedia("noext"))
}
