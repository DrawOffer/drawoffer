import Foundation
import Testing
@testable import DrawOfferCore

@Test func jobPoolSplitsOfficialBodyIntoSectionsAndPoints() {
    let text = "负责虚构产品的后端服务\n岗位职责：\n1、设计接口\n2. 维护数据\n任职要求：本科及以上\n- 熟悉 Python\n加分项"
    let sections = JobPool.sections(text)
    #expect(sections.map(\.title) == ["岗位描述", "岗位职责", "任职要求"])
    #expect(sections[1].blocks == [.points(["设计接口", "维护数据"])])
    #expect(sections[2].blocks == [.paragraph("本科及以上"), .points(["熟悉 Python"])])
    #expect(JobPool.sections("").isEmpty)
}

@Test func jobPoolFormatsRecruitmentAndRelativeTime() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = ISO8601DateFormatter().date(from: "2026-10-30T04:00:00Z")!
    #expect(JobPool.relative("2026-10-30T01:00:00Z", now: now, calendar: calendar) == "今天")
    #expect(JobPool.relative("2026-10-27T01:00:00Z", now: now, calendar: calendar) == "3 天前")
    #expect(JobPool.relative("2026-10-16T01:00:00Z", now: now, calendar: calendar) == "2 周前")
    #expect(JobPool.relative("2025-09-01T01:00:00Z", now: now, calendar: calendar) == "2025年9月1日")
    let job: JSONValue = .object(["employment_type": .string("full_time"), "recruitment_channel": .string("campus")])
    #expect(JobPool.recruitment(job) == "校招")
    #expect(JobPool.jobType(job) == "校招 · 正式")
}
