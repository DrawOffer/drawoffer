import Foundation
import Testing
@testable import DrawOfferCore

private func template(_ id: String, _ useCases: [String]) throws -> ResumeTemplate {
    let cases = useCases.map { "\"\($0)\"" }.joined(separator: ",")
    let json = #"{"id":"\#(id)","key":"t\#(id)","name":"虚构模板 \#(id)","style_categories":[],"use_cases":[\#(cases)],"data":{},"style":{}}"#
    return try JSONDecoder().decode(ResumeTemplate.self, from: Data(json.utf8))
}

@Test func resumeCreatePickerShowsOnlyCategoriesWithTemplates() throws {
    let templates = [try template("1", ["技术研发"]), try template("2", ["设计", "产品"]), try template("3", ["技术研发"])]
    #expect(ResumeCreatePicker.categories(templates).map(\.value) == ["all", "技术研发", "产品", "设计"])
    #expect(ResumeCreatePicker.visible(templates, category: "技术研发").map(\.id) == ["1", "3"])
    #expect(ResumeCreatePicker.visible(templates, category: ResumeCreatePicker.all).count == 3)
    // 换类时原选中还在就不动，不在就取这一类第一套，空类保持原样
    #expect(ResumeCreatePicker.selection(after: "技术研发", in: templates, current: "3") == "3")
    #expect(ResumeCreatePicker.selection(after: "设计", in: templates, current: "3") == "2")
    #expect(ResumeCreatePicker.selection(after: "职能", in: templates, current: "3") == "3")
}

@Test func resumeCreatePickerMovesWithArrowKeys() {
    let ids = (1...7).map(String.init)
    #expect(ResumeCreatePicker.move(ids, current: "1", columns: 5, key: .left) == "7")
    #expect(ResumeCreatePicker.move(ids, current: "7", columns: 5, key: .right) == "1")
    #expect(ResumeCreatePicker.move(ids, current: "2", columns: 5, key: .down) == "7")
    #expect(ResumeCreatePicker.move(ids, current: "3", columns: 5, key: .down) == "3")
    #expect(ResumeCreatePicker.move(ids, current: "6", columns: 5, key: .up) == "1")
    #expect(ResumeCreatePicker.move(ids, current: "2", columns: 5, key: .up) == "2")
    #expect(ResumeCreatePicker.move([], current: nil, columns: 5, key: .right) == nil)
}

@Test func resumeShareMatchesExpiryOptionAndLabel() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-26T04:00:00Z")!
    func share(_ expires: String?) -> ResumeShare? {
        var object: [String: JSONValue] = ["share_token": .string("k7QmVx2p9Lr"), "share_visibility": .string("public")]
        if let expires { object["share_expires_at"] = .string(expires) }
        return ResumeShare(.object(object))
    }
    let forever = try #require(share(nil))
    #expect(forever.expiry(now: now) == .forever)
    #expect(forever.expiryLabel(now: now) == "永久有效")
    #expect(forever.allowDownload)
    let week = try #require(share("2026-12-03T04:20:00Z"))
    #expect(week.expiry(now: now) == .week)
    #expect(week.expiryLabel(now: now) == "有效至 2026-12-03 12:20")
    #expect(try #require(share("2026-12-26T03:30:00Z")).expiry(now: now) == .month)
    #expect(try #require(share("2026-12-10T04:00:00Z")).expiry(now: now) == nil)
    #expect(try #require(share("2026-11-20T02:00:00Z")).expiryLabel(now: now).hasPrefix("已于 2026-11-20 10:00"))
    #expect(ResumeShare(.object(["share_token": .string("")])) == nil)
}

@Test func resumeOrbTalksAboutTheUnitUnderTheCursor() {
    let idle = ResumeOrb.dialogue(unitID: nil, unitLabel: nil)
    #expect(idle.say == "想改哪儿？点纸上任意一段，我就去那一段。")
    #expect(idle.actions == [.deepenAll, .layout])
    #expect(idle.accent == .deepenAll)
    let unit = ResumeOrb.dialogue(unitID: "e_1", unitLabel: "项目经历 · 分布式任务调度平台")
    #expect(unit.say == "想改「分布式任务调度平台」的话，我先看看这段，再问你几句当时的情况。")
    #expect(unit.actions.map(\.label) == ["改这一段", "智能排版"])
    #expect(unit.note == "改好会先写在纸上，你看过再换上。")
    #expect(ResumeOrb.dialogue(unitID: "e_1", unitLabel: "  ").actions.first == .deepenAll)
    #expect(ResumeOrb.compactUnitName("实习经历 · 一家名字非常非常长的虚构科技公司") == "一家名字非常非常长的虚构…")
    #expect(ResumeOrb.shortLabel("  示例   科技 ") == "示例 科技")
}
