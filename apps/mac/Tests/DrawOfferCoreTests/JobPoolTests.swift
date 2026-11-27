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

@Test func jobPoolReadsStructuredBodyWithPairs() {
    let job: JSONValue = .object(["description": .string("岗位职责：\n1. 旧正文"), "description_sections": .object(["schema_version": .number(1), "sections": .array([
        .object(["key": .string("overview"), "title": .string("岗位详情"), "items": .array([
            .object(["type": .string("kv"), "label": .string("学历要求"), "value": .string("本科及以上")]),
            .object(["type": .string("kv"), "label": .string("办公模式"), "value": .string("混合办公")]),
            .object(["type": .string("list"), "text": .string("负责虚构网关")]),
            .object(["type": .string("text"), "text": .string("欢迎加入")]),
        ])]),
        .object(["key": .string("other"), "title": .string("空段"), "items": .array([])]),
    ])])])
    let sections = JobPool.body(job)
    #expect(sections.map(\.title) == ["岗位详情"])
    #expect(sections[0].blocks == [.pairs([.init("学历要求", "本科及以上"), .init("办公模式", "混合办公")]), .points(["负责虚构网关"]), .paragraph("欢迎加入")])
    // 没有分段数据时退回纯文本拆法；分段全空时什么都不显示（交给空正文兜底）。
    #expect(JobPool.body(.object(["description": .string("岗位职责：\n1. 旧正文")])).first?.blocks == [.points(["旧正文"])])
    #expect(JobPool.body(.object(["description_sections": .object(["sections": .array([])])])).isEmpty)
}

@Test func jobPoolPlazaBuildsQueriesAndLabels() {
    var plaza = PoolPlaza()
    #expect(plaza.filterLabel == "筛选")
    #expect(!plaza.filtered)
    #expect(plaza.listQuery(keyword: "", seed: "abc") == ["sort": "recommend", "seed": "abc"])
    plaza.panel.cities = ["上海", "北京"]
    plaza.panel.categories = ["研发"]
    plaza.type = "campus"; plaza.intent = true
    #expect(plaza.filterLabel == "上海、北京 · 研发")
    #expect(plaza.filter(keyword: "后端") == ["keyword": "后端", "recruitment_type": "campus", "intent": "true", "city": JobPool.multi(["北京", "上海"]), "job_category": "研发"])
    // 搜索时综合改按相关度，不带种子；最新发布也不带种子。
    #expect(plaza.listQuery(keyword: "后端", seed: "abc", cursor: "c1")["sort"] == "relevance")
    #expect(plaza.listQuery(keyword: "后端", seed: "abc")["seed"] == nil)
    plaza.panel.sort = "published"
    #expect(plaza.listQuery(keyword: "", seed: "abc")["seed"] == nil)
    plaza.panel.cities = ["北京", "上海", "深圳"]
    #expect(plaza.filterLabel == "北京、上海 等 3 城 · 研发")
    var timeOnly = PoolPlaza(); timeOnly.panel.within = "7d"; timeOnly.panel.excludeJoined = true
    #expect(timeOnly.filterLabel == "筛选 · 2 项")
    #expect(timeOnly.panel.query == ["published_within": "7d", "exclude_joined": "true"])
    plaza.q = "后端"
    #expect(plaza.emptySummary == "后端 · 北京 · 上海 · 深圳 · 研发 · 校招")
    plaza.mode = .company
    #expect(plaza.cleared().mode == .company && !plaza.cleared().filtered)
    #expect(PoolPlaza.keyword(" 后 ") == "" && PoolPlaza.keyword(" 后端 ") == "后端")
    var one = PoolPlaza(); one.panel.cities = ["杭州"]; one.panel.categories = ["产品", "设计"]
    #expect(one.carry(keyword: "运营") == ("运营", "杭州", "", ""))
}

@Test func jobPoolMultiValueQueryExpandsToRepeatedParameters() {
    let value = JobPool.multi(["上海", "北京", "上海"])
    let items = JobPool.queryItems(["city": value, "sort": "recommend"])
    #expect(items.map(\.name) == ["city", "city", "sort"])
    #expect(Set(items.compactMap(\.value)) == ["北京", "上海", "recommend"])
    #expect(JobPool.multi(["上海", "北京"]) == JobPool.multi(["北京", "上海"]))
}

@Test func jobPoolPanelKeepsCityOrderAndPickedItems() {
    let order = ["北京", "上海", "深圳", "杭州", "广州", "成都", "南京", "武汉", "西安", "苏州", "宁波"]
    #expect(JobPool.panelCities(order: order, counted: order, picked: ["宁波"], needle: "", all: false) == ["宁波"] + Array(order.prefix(9)))
    #expect(JobPool.panelCities(order: order, counted: order, picked: [], needle: "", all: true) == order)
    #expect(JobPool.panelCities(order: order, counted: order + ["南通"], picked: [], needle: "南", all: false) == ["南京", "南通"])
    #expect(JobPool.hasMoreCities(order: order, needle: ""))
    #expect(!JobPool.hasMoreCities(order: order, needle: "南"))
    let categories = JobPool.sortCategories(["其他", "运营", "研发", "产品", "法务", "设计", "技术", "职能", "质量", "供应链", "市场与销售"])
    #expect(Array(categories.prefix(4)) == ["研发", "技术", "产品", "设计"])
    #expect(JobPool.panelCategories(categories, picked: ["法务"], all: false).count == 10)
}

@Test func jobPoolIntentDeadlineAndHighlight() {
    let ready = PoolIntent(.object(["state": .string("ready"), "target_role": .string("后端工程师"), "category": .string("研发"),
                                    "cities": .array([.string("上海"), .string("杭州")]), "types": .array([.string("campus")]),
                                    "profile_ready": .bool(false), "missing": .array([.object(["key": .string("skills"), "label": .string("技能")])])]))
    #expect(ready.ready && ready.summary == "研发 · 上海、杭州 · 校招")
    #expect(ready.tip == "补全技能后可按匹配度优先排序")
    #expect(PoolIntent(.object(["state": .string("ready"), "target_role": .string("产品经理"), "cities": .array([]), "types": .array([])])).summary == "产品经理")
    #expect(PoolIntent(nil).state == "signed_out")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = ISO8601DateFormatter().date(from: "2026-10-13T04:00:00Z")!
    #expect(JobPool.deadline("2026-11-30", now: now, calendar: calendar) == .left("11月30日", days: 48))
    #expect(JobPool.deadline("2026-10-13", now: now, calendar: calendar) == .today)
    #expect(JobPool.deadline("2025-10-01", now: now, calendar: calendar) == .past("2025年10月1日"))
    #expect(JobPool.deadline("待定", now: now, calendar: calendar) == nil)
    let parts = JobPool.highlight("Go 后端 Google", keyword: "go 后端")
    #expect(parts.filter(\.hit).map(\.text) == ["Go", "后端"])
    #expect(JobPool.cityLabel(["北京", "上海", "深圳", "杭州"]) == "北京、上海、深圳…")
    #expect(JobPool.cityLabel([]) == "地点未标明")
    #expect(JobPool.nextPage(1, pageSize: 21, total: 30) == 2 && JobPool.nextPage(2, pageSize: 21, total: 30) == nil)
    #expect(JobPool.grouped(8916) == "8,916")
}
