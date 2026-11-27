import Foundation
import Testing
@testable import DrawOfferCore

/// 与 Web `avatarCrop.test.ts` 同样的两组用例。
@Test func avatarCropMatchesWeb() {
    let layout = AvatarCrop.layout(.init(width: 640, height: 480))
    #expect(layout.renderedWidth == 352)
    #expect(layout.renderedHeight == 264)
    #expect(layout.maxOffsetX == 44)
    #expect(layout.maxOffsetY == 0)
    #expect(abs(layout.scale - 0.55) < 1e-9)
    let clamped = AvatarCrop.clamp(.init(width: 640, height: 480, offsetX: 100, offsetY: 100))
    #expect(clamped.offsetX == 44)
    #expect(clamped.offsetY == 0)

    let source = AvatarCrop.source(.init(width: 640, height: 480, zoom: 2))
    #expect(abs(source.x - 200) < 1e-6)
    #expect(abs(source.y - 120) < 1e-6)
    #expect(abs(source.size - 240) < 1e-6)
}

@Test func careerProfileRules() {
    let profile = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"personal":{"name":"虚构","email":"a@example.com"},"has_id_number":false,"catalog":{"fields":{"a":{"scope":"personal","key":"height","label":"身高"},"b":{"scope":"personal","key":"name","label":"姓名"},"c":{"scope":"personal","key":"x","label":"站点","site":"alibaba"}}}}"#.utf8))
    #expect(CareerProfileRules.missing(profile) == ["gender", "birth_date", "phone", "ethnicity", "political_status", "native_place", "id_number"])
    let experience = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"sections":[{"kind":"work","entries":[{"id":"1","fields":{"单位":"虚构公司"},"intern":true}]},{"kind":"skills","lines":["编程：Swift、Python；工具: Git"],"entries":[]}]}"#.utf8))
    #expect(CareerProfileRules.skills(experience).map(\.name) == ["Swift", "Python", "Git"])
}
