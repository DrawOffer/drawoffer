import Foundation

/// 模拟面试首页（Web `v2/homeV3Model.ts` + `HomeV3.tsx` 的取数规则）：接下来的一场、中间抛出的那道题、默认配置一行与底部长期记忆。
/// 只读已有接口（overview、面试日程、投递、答辩提纲、岗位要求对照），全部由规则得出，不调模型。
public enum MockHome {
    public static let minutesPerQuestion = 5
    public static let fullCount = 8
    public static let firstCount = 3
    static let shownItems = 3
    static let levels = ["了解", "熟悉", "掌握", "精通", "专家"]

    public static func levelName(_ level: Int?) -> String {
        guard let level, level >= 1 else { return "" }
        return levels[min(5, max(1, level)) - 1]
    }

    // MARK: 场次

    /// 首页能选的一场：日程里还没开始的面试，或者不针对岗位的通用练习。
    public enum Target: Equatable, Sendable {
        case session(JSONValue, application: JSONValue?)
        case general
        public var session: JSONValue? { if case .session(let value, _) = self { return value }; return nil }
        public var application: JSONValue? { if case .session(_, let value) = self { return value }; return nil }
        public var id: String { session?.display("id") ?? "general" }
    }

    /// 还值得按它准备下一场面试的投递（Web `preparableApplication`）：进行中、没归档、没结束，也还没走到 Offer。
    public static func preparable(_ application: JSONValue) -> Bool {
        let stage = application["current_stage"]?.text("stage_type").nonEmptyValue ?? application.text("current_stage_type")
        let offer = application.text("offer_status")
        return application.text("status") == "active" && (application["archived_at"] ?? .null) == .null
            && application.text("lifecycle_status") != "terminated" && (offer.isEmpty || offer == "none") && stage != "offer"
    }

    static func date(_ text: String) -> Date { CareerApplication.date(text) ?? .distantPast }

    /// 日程里接下来的面试（一面二面与 HR 面），已到 Offer 或已结束的岗位不推荐。
    public static func upcomingSessions(_ sessions: [JSONValue], applications: [JSONValue], now: Date) -> [JSONValue] {
        let live = Set(applications.filter(preparable).map { $0.display("id") })
        return sessions
            .filter { ["interview", "hr"].contains($0.text("stage_type")) && $0.text("status") == "scheduled" && date($0.text("end_at")) >= now && live.contains($0.display("application_id")) }
            .sorted { date($0.text("start_at")) < date($1.text("start_at")) }
    }

    public static func sessionTitle(_ session: JSONValue) -> String { session.text("company_name") + session.text("stage_label") }

    public static func mmdd(_ value: String, calendar: Calendar = Beijing.calendar) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }

    public static func whenLabel(_ start: Date, now: Date, calendar: Calendar = Beijing.calendar) -> String {
        let diff = max(0, MockMap.dayDiff(now, start, calendar: calendar))
        return diff == 0 ? "今天" : diff == 1 ? "明天" : "\(diff) 天后"
    }

    /// 首页左上那一段：「3 天后 · 云川科技 后端二面」。
    public static func switchLabel(_ session: JSONValue, now: Date, calendar: Calendar = Beijing.calendar) -> String {
        let job = session.text("job_title")
        let stage = session.text("stage_label")
        let name = job.isEmpty ? stage : (job.hasSuffix("工程师") ? String(job.dropLast(3)) : job) + stage
        return "\(whenLabel(date(session.text("start_at")), now: now, calendar: calendar)) · \(session.text("company_name")) \(name)"
    }

    /// 这条投递在这场之前最近的一场真实面试（上一轮）。
    public static func previousRound(_ records: [JSONValue], applicationID: String, before: Date) -> JSONValue? {
        records.filter { $0.text("kind") == "real" && $0.display("application_id") == applicationID && $0["unrecorded"]?.bool != true
            && $0.text("status") != "abandoned" && date($0.text("at")) < before }
            .sorted { $0.text("at") > $1.text("at") }.first
    }

    /// 换一场弹层里每一场下面那句：几天后 · 上一轮多少分 / 首次面试。
    public static func sessionLine(_ session: JSONValue, records: [JSONValue], now: Date, calendar: Calendar = Beijing.calendar) -> String {
        let start = date(session.text("start_at"))
        let when = MockMap.dayDiff(now, start, calendar: calendar) <= 7 ? whenLabel(start, now: now, calendar: calendar) : mmdd(session.text("start_at"), calendar: calendar)
        guard let previous = previousRound(records, applicationID: session.display("application_id"), before: start) else { return "\(when) · 首次面试" }
        return "\(when) · " + (previous["score"]?.numberValue.map { "上一轮 \(Int($0)) 分" } ?? "上一轮复盘中")
    }

    // MARK: 可以单独练的几处

    public struct Item: Equatable, Sendable {
        public var key: String
        public var name: String
        public var sub: String
        public var level: Int?
        public var target: Int?
        /// 右边那句：要求的层没到为橙色，到了为蓝色，没练过为灰色
        public var tone: String
        public var right: String
        /// 点这一处时问的原题（没有时只给考点，后端按考点出开场题）
        public var question: String
        public var signals: [String]
        /// 原题是哪场的哪一题（mock|real:场次:题号）
        public var source: String?
        public var practised: Bool
    }

    public struct Model: Equatable, Sendable {
        public var title: String
        public var items: [Item]
        public var previous: JSONValue?
        public var latest: JSONValue?
        /// 第一次面这家时主按钮是「先练一场」
        public var primary: String
    }

    static func int(_ value: JSONValue?) -> Int? { value?.numberValue.map { Int($0.rounded()) } }
    static func strings(_ value: JSONValue?) -> [String] { (value?.items ?? []).compactMap(\.stringValue) }

    static func right(level: Int?, target: Int?, practised: Bool) -> (String, String) {
        guard let level, level > 0 else { return ("gray", "还没练过") }
        if let target, level < target { return ("orange", "达到「\(levelName(level))」，要求「\(levelName(target))」") }
        return ("blue", "达到「\(levelName(level))」")
    }

    static func topicSub(_ topic: JSONValue) -> String {
        if let note = topic.text("note").nonEmptyValue { return note.hasSuffix("。") ? String(note.dropLast()) : note }
        return topic.text("detail").nonEmptyValue.map { "停在\($0)" } ?? "没答到位"
    }

    static func item(key: String, name: String, sub: String, level: Int?, target: Int?, practised: Bool = false,
                     question: String = "", signals: [String] = [], source: String? = nil) -> Item {
        let (tone, right) = right(level: level, target: target, practised: practised)
        return Item(key: key, name: name, sub: sub, level: level, target: target, tone: tone, right: right, question: question, signals: signals, source: source, practised: practised)
    }

    /// 上一轮没答好的几处：那场每题的结论；之后答到位（进了“已经掌握”）的算练过。
    static func roundItems(_ record: JSONValue, overview: JSONValue) -> [Item] {
        let mastered = Set(strings(overview["mastered"]))
        var open: [String: JSONValue] = [:]
        for topic in overview["open_topics"]?.items ?? [] where open[topic.text("topic")] == nil { open[topic.text("topic")] = topic }
        var seen = Set<String>()
        return (record["topics"]?.items ?? [])
            .filter { ["one_short", "missed"].contains($0.text("outcome")) }
            .filter { seen.insert($0.text("name")).inserted }
            .prefix(shownItems)
            .map { topic in
                let name = topic.text("name"), practised = mastered.contains(name), latest = open[name]
                let level = practised ? (max(int(topic["target"]) ?? 0, int(topic["level"]) ?? 0).nonZero ?? int(topic["level"])) : (int(latest?["level"]) ?? int(topic["level"]))
                let target = int(latest?["target"]) ?? int(topic["target"])
                let ref = topic.display("ref")
                let question = topic.text("question")
                return item(key: "r:\(ref.isEmpty ? name : ref)", name: name, sub: practised ? "之后已练到位" : topicSub(topic), level: level, target: target, practised: practised,
                            question: question, signals: strings(topic["signals"]),
                            source: !question.isEmpty && !ref.isEmpty ? "\(record.text("kind")):\(record.display("id")):\(ref)" : nil)
            }
    }

    static func openItems(_ topics: [JSONValue]) -> [Item] {
        topics.prefix(shownItems).map { topic in
            let stops = int(topic["stops"]) ?? 0
            let detail = topic.text("detail").nonEmptyValue
            return item(key: "o:\(topic.text("topic"))", name: topic.text("topic"),
                        sub: stops > 1 ? "\(stops) 次都没答好" + (detail.map { "“\($0)”" } ?? "") : topicSub(topic),
                        level: int(topic["level"]), target: int(topic["target"]), question: topic.text("question"),
                        signals: strings(topic["signals"]), source: topic.text("source").nonEmptyValue)
        }
    }

    /// 第一次面这家：简历里最先被问的经历、岗位要求里还没达到的几项、提纲里的基础知识。
    static func reviewItems(outline: JSONValue?, match: JSONValue?, overview: JSONValue) -> [Item] {
        var items: [Item] = []
        var names = Set<String>()
        var open: [String: JSONValue] = [:]
        for topic in overview["open_topics"]?.items ?? [] where open[topic.text("topic")] == nil { open[topic.text("topic")] = topic }
        let enabled = outline?["enabled"]?.bool == true
        let hooks = enabled ? outline?["hooks"]?.items ?? [] : []
        if let hook = hooks.first(where: { !$0.text("experience").isEmpty }) ?? hooks.first {
            let experience = hook.text("experience").nonEmptyValue
            let name = String((experience ?? hook.text("text")).prefix(24))
            let level = hook["held"]?.text("status") == "untested" ? nil : int(hook["held"]?["level"])
            names.insert(name)
            items.append(item(key: "h:\(hook.display("id"))", name: name, sub: experience != nil ? "简历里的经历，面试通常从这里问起" : "简历里写了，可能被追问",
                              level: level, target: int(hook["target_level"]), question: hook["follow_ups"]?.items.first?.text("question") ?? ""))
        }
        if match?["enabled"]?.bool == true, match?.text("match_status") == "ready" {
            for requirement in match?["requirements"]?.items ?? [] {
                if items.count >= shownItems { break }
                let interview = requirement["interview"]
                if requirement.text("group") == "qualification" || interview?["met"]?.bool == true || interview?.text("status") == "not_applicable" { continue }
                let name = requirement["nodes"]?.items.first?.text("name").nonEmptyValue ?? interview?["skills"]?.items.first?.text("name").nonEmptyValue
                    ?? String(requirement.text("text").prefix(16))
                if name.isEmpty || names.contains(name) { continue }
                names.insert(name)
                let topic = open[name]
                let sub = requirement["unwritten"]?.bool == true ? "岗位要求里有，简历里没写" : topic.map { "岗位要求里有，上次\(topicSub($0))" } ?? "岗位要求里有"
                items.append(item(key: "j:\(requirement.display("id").nonEmptyValue ?? name)", name: name, sub: sub, level: int(topic?["level"]), target: int(topic?["target"]),
                                  question: topic?.text("question") ?? "", signals: strings(topic?["signals"])))
            }
        }
        for basic in enabled ? outline?["basics"]?.items ?? [] : [] {
            if items.count >= shownItems { break }
            let name = basic.text("name")
            if names.contains(name) { continue }
            names.insert(name)
            let topic = open[name]
            items.append(item(key: "b:\(basic.display("node"))", name: name, sub: basic.text("kind") == "review_due" ? "之前答过，隔了一段时间" : "简历里写了，还没练过",
                              level: int(topic?["level"]), target: int(topic?["target"]), question: topic?.text("question") ?? "", signals: strings(topic?["signals"])))
        }
        return items
    }

    static func latestScored(_ records: [JSONValue]) -> JSONValue? {
        records.filter { $0.text("status") == "completed" && $0["score"]?.numberValue != nil }.sorted { $0.text("at") > $1.text("at") }.first
    }

    public static func build(target: Target, overview: JSONValue, now: Date, outline: JSONValue?, match: JSONValue?) -> Model {
        let records = overview["records"]?.items ?? []
        let latest = latestScored(records)
        let open = overview["open_topics"]?.items ?? []
        guard case .session(let session, let application) = target else {
            return Model(title: "通用练习", items: openItems(open), previous: nil, latest: latest, primary: "")
        }
        let start = date(session.text("start_at"))
        if let previous = previousRound(records, applicationID: session.display("application_id"), before: start) {
            if previous.text("status") == "reviewing" {
                return Model(title: sessionTitle(session), items: open.isEmpty ? reviewItems(outline: outline, match: match, overview: overview) : openItems(open),
                             previous: previous, latest: latest, primary: "")
            }
            return Model(title: sessionTitle(session), items: roundItems(previous, overview: overview), previous: previous, latest: latest, primary: "")
        }
        _ = application
        return Model(title: sessionTitle(session), items: reviewItems(outline: outline, match: match, overview: overview), previous: nil, latest: latest, primary: "先练一场")
    }

    /// 没有排期时：页头只写练过几场，下面同通用练习。
    public static func idle(_ overview: JSONValue) -> Model {
        Model(title: "最近没有安排面试", items: openItems(overview["open_topics"]?.items ?? []), previous: nil, latest: latestScored(overview["records"]?.items ?? []), primary: "")
    }

    // MARK: 中间那道题

    public struct Hero: Equatable, Sendable {
        public var eyebrow: String
        public var tail: String?
        public var question: String
        public var sub: String?
        public var item: Item?
        /// 上次卡住（橙点）还是推进新考点（蓝点）
        public var stuck: Bool
    }

    public static func masteredCount(_ overview: JSONValue) -> Int {
        max(strings(overview["mastered"]).count, int(overview["tallies"]?["cleared"]?["count"]) ?? 0)
    }

    /// 上次卡住的那一处；没有卡住时下面第一处还没练的。
    public static func hero(_ overview: JSONValue, model: Model) -> Hero? {
        let pending = model.items.first { !$0.practised }
        if let stuck = overview["stuck"], stuck != .null, !stuck.text("topic").isEmpty {
            let topic = stuck.text("topic"), times = int(stuck["times"]) ?? 0
            let said = stuck["records"]?.items.first { !$0.text("quote").isEmpty }
            let found = model.items.first { $0.name == topic } ?? pending
            var sub: String?
            if let said {
                var quote = said.text("quote")
                while let last = quote.last, "。…".contains(last) || last.isWhitespace { quote.removeLast() }
                sub = "\(mmdd(said.text("date"))) \(said.text("title"))你说到：“\(quote)……”"
            } else if let detail = stuck.text("detail").nonEmptyValue { sub = "上次停在\(detail)" }
            return Hero(eyebrow: "接着上次卡住的第 1 题", tail: times >= 2 ? "\(topic) · 已停过 \(times) 场" : topic,
                        question: (stuck.text("question").nonEmptyValue ?? topic).trimmingCharacters(in: .whitespacesAndNewlines), sub: sub,
                        item: found ?? item(key: "s:\(topic)", name: topic, sub: "", level: nil, target: nil, question: stuck.text("question"), signals: strings(stuck["signals"])),
                        stuck: true)
        }
        guard let pending else { return nil }
        let last = model.previous ?? model.latest
        let allGood = last != nil && (overview["open_topics"]?.items ?? []).isEmpty
        let lastCount = int(last?["question_count"]) ?? last?["topics"].map { $0.items.count }
        let mastered = masteredCount(overview)
        let sub = [mastered > 0 ? "已答稳的 \(mastered) 处自动跳过" : nil, pending.sub.nonEmptyValue].compactMap { $0 }.joined(separator: " · ")
        return Hero(eyebrow: allGood ? (lastCount.map { "上次 \($0) 题已全部答稳" } ?? "上次已全部答稳") : "先从这一处练起",
                    tail: allGood ? "挑了一处简历里还没深挖过的" : pending.name,
                    question: (pending.question.nonEmptyValue ?? pending.name).trimmingCharacters(in: .whitespacesAndNewlines),
                    sub: sub.nonEmptyValue, item: pending, stuck: false)
    }

    /// 题目按第一句收尾断成两行（「你提到 AOF 重写。」「重写时来了新写入，数据怎么不丢？」），断不开就一整句。
    public static func splitQuestion(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        for index in chars.indices where "。！？!?".contains(chars[index]) {
            let head = index + 1
            guard head >= 5 else { continue }
            if head > 41 { break }
            let rest = String(chars[head...]).trimmingCharacters(in: .whitespaces)
            if rest.count >= 4 { return [String(chars[..<head]), rest] }
        }
        return [trimmed]
    }

    // MARK: 主按钮与默认配置

    public struct Primary: Equatable, Sendable {
        public var label: String
        public var minutes: Int
        public var plan: MockStart.Plan
        public var showSecondary: Bool
    }

    /// 主按钮：有进行中 / 等报告的一场时先去那一场；第一次面这家「先练一场」3 题；有可练的几处「接着练」；否则完整模拟。
    public static func primary(model: Model, hero: Hero?, active: Bool, evaluating: Bool) -> Primary {
        let pending = model.items.filter { !$0.practised }
        var set = pending
        if let item = hero?.item, !item.practised { set = [item] + pending.filter { $0.key != item.key } }
        set = Array(set.prefix(3))
        let first = model.primary == "先练一场" && hero == nil
        let plan: MockStart.Plan = first ? .full(count: firstCount, title: "先练一场")
            : set.isEmpty ? .full(count: nil, title: nil) : .set(set.map(MockStart.Item.init), title: "接着练")
        let minutes = (first ? firstCount : set.isEmpty ? fullCount : set.count) * minutesPerQuestion
        let label = active ? "继续这一场" : evaluating ? "看上一场" : first ? "先练一场" : set.isEmpty ? "完整模拟" : "接着练"
        return Primary(label: label, minutes: minutes, plan: plan, showSecondary: !active && !evaluating && label != "完整模拟")
    }

    /// 默认配置一行：针对云川二面 · 专业面 · 中级 · 语音 · 简历名。
    public static func settingsLine(target: Target, resumeTitle: String?) -> String {
        let session = target.session
        return [session.map { "针对\($0.text("company_name"))\($0.text("stage_label"))" } ?? "按简历通用",
                session?.text("stage_type") == "hr" ? "HR 面" : "专业面", "中级", "语音", resumeTitle?.nonEmptyValue]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 底部长期记忆

    /// 待加强一行下面那句：停过几场或哪一场 · 卡在哪。
    public static func openLine(_ topic: JSONValue) -> String {
        let stops = int(topic["stops"]) ?? 0
        let latest = topic["latest"]
        let first = stops > 1 ? "停过 \(stops) 场" : "\(mmdd(latest?.text("date") ?? "")) \(latest?.text("kind") == "mock" ? "模拟" : latest?.text("title") ?? "")"
        var second = topic.text("detail").nonEmptyValue.map { "卡在\($0)" }
        if second == nil, var note = topic.text("note").nonEmptyValue { if note.hasSuffix("。") { note.removeLast() }; second = note }
        return [first, second].compactMap { $0 }.joined(separator: " · ")
    }

    /// 这一处最近一次答到位的那一场：日期和场次名。
    public static func reachedIn(_ records: [JSONValue], name: String) -> String? {
        guard let found = records.sorted(by: { $0.text("at") > $1.text("at") })
            .first(where: { ($0["topics"]?.items ?? []).contains { $0.text("name") == name && $0.text("outcome") == "reached" } }) else { return nil }
        return "\(mmdd(found.text("at"))) \(found.text("kind") == "mock" ? "模拟" : found.text("title"))"
    }
}

/// 开始前确认弹窗（Web `v2/StartDialog.tsx`）：这一场练什么、几题几分钟、积分与 `practice_focus`。
public enum MockStart {
    public struct Item: Equatable, Hashable, Sendable {
        public var label: String
        public var question: String
        public var signals: [String]
        public var source: String?
        public init(label: String, question: String = "", signals: [String] = [], source: String? = nil) {
            self.label = label; self.question = question; self.signals = signals; self.source = source
        }
        public init(_ item: MockHome.Item) { self.init(label: item.name, question: item.question, signals: item.signals, source: item.source) }
    }

    public struct Experience: Equatable, Hashable, Sendable {
        public var ref: String
        public var label: String
        public var scope: String?
        public var hook: String?
        public var short: Bool
        public var origin: String?
        public init(ref: String, label: String, scope: String? = nil, hook: String? = nil, short: Bool = false, origin: String? = nil) {
            self.ref = ref; self.label = label; self.scope = scope; self.hook = hook; self.short = short; self.origin = origin
        }
    }

    /// 这一场练什么：练这几处、练这一处、完整模拟、从复盘报告带来的几题，或练经历。
    public enum Plan: Equatable, Hashable, Sendable {
        case set([Item], title: String?)
        case single(Item, ref: String?, focusKind: String?, origin: String?)
        case full(count: Int?, title: String?)
        case practice([Item])
        case experience(Experience)
    }

    /// 练经历一场最多练几个点（服务端 experience_practice 同一上限）
    public static let experienceMaxPoints = 5
    public static let followUps = ["junior": 2, "intermediate": 2, "senior": 3]

    public static func count(_ plan: Plan, packaged: Int = 0, pending: Int = 0, scope: String = "packaged") -> Int {
        switch plan {
        case .set(let items, _), .practice(let items): return items.count
        case .single: return 1
        case .full(let count, _): return count ?? MockHome.fullCount
        case .experience(let experience):
            // 题数服务端定：只练延伸点时按还没练透的延伸点估（至少 1 个），整段按上限估；开场介绍另算一题（短版没有）
            let points = scope == "packaged" && packaged > 0 ? max(1, pending) : experienceMaxPoints
            return min(experienceMaxPoints, points) + (experience.short ? 0 : 1)
        }
    }

    public static func title(_ plan: Plan, hasSession: Bool) -> String {
        switch plan {
        case .set(let items, let title): return title ?? "练这 \(items.count) 处"
        case .single(let item, _, _, _): return item.label
        case .practice(let items): return items.count > 1 ? "练这 \(items.count) 题" : items.first?.label ?? "练这一题"
        case .experience: return "练这段经历"
        case .full(_, let title): return title ?? (hasSession ? "完整模拟" : "通用练习")
        }
    }

    public static func subtitle(_ plan: Plan, count: Int, packaged: Int = 0) -> String {
        if case .experience(let experience) = plan { return [experience.label, packaged > 0 ? "\(packaged) 处延伸点" : ""].filter { !$0.isEmpty }.joined(separator: " · ") }
        let minutes = count * MockHome.minutesPerQuestion
        var single = false
        if case .single = plan { single = true }
        if case .practice = plan, count == 1 { single = true }
        return single ? "单题练习 · 约 \(minutes) 分钟" : "\(count) 题 · 约 \(minutes) 分钟"
    }

    /// 范围下面的一句说明：问什么、怎么问；不写时长。
    public static func scopeNote(_ experience: Experience, scope: String, packaged: Int, loaded: Bool) -> String {
        if experience.hook != nil { return "先问\(experience.label)，沿着追问一轮轮往下问" }
        if scope == "packaged" { return packaged > 0 ? "专问新补上的 \(packaged) 处延伸点，沿着追问一轮轮往下问" : "专问新补上的延伸点，沿着追问一轮轮往下问" }
        return loaded && packaged == 0 ? "这段还没有延伸点，按整段经历从头问，沿着追问一轮轮往下问" : "从这段经历的开场介绍问起，延伸点和原有做法都会问到"
    }

    /// 积分：文字定价为主，语音另有定价时按语音；免费、按量计。
    public struct Cost: Equatable, Sendable { public var label: String; public var points: Double? }

    public static func cost(text: JSONValue?, voice: JSONValue?, count: Int) -> Cost? {
        func mode(_ price: JSONValue?) -> String { price?.text("priceMode").nonEmptyValue ?? price?.text("price_mode") ?? "" }
        func unit(_ price: JSONValue?) -> Double? {
            let value = price?["unitPoints"] ?? price?["unit_points"]
            return value?.numberValue ?? value?.stringValue.flatMap(Double.init)
        }
        if mode(text) == "free" { return Cost(label: "本次免费", points: 0) }
        if mode(text) == "usage" { return Cost(label: "按实际用量计积分", points: nil) }
        guard mode(text) == "fixed", let base = unit(text) else { return nil }
        if mode(voice) == "free" { return Cost(label: "本次免费", points: 0) }
        let per = mode(voice) == "fixed" ? unit(voice) ?? base : base
        let points = (per * Double(count) * 100).rounded() / 100
        return Cost(label: "消耗 \(number(points)) 积分", points: points)
    }

    public static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", (value * 100).rounded() / 100)
    }

    /// 创建时带的 `practice_focus`（完整模拟不带）。
    public static func practiceFocus(_ plan: Plan, scope: String, packaged: Int) -> JSONValue? {
        func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }
        if case .experience(let experience) = plan {
            var fields: [String: JSONValue] = [
                "kind": .string("experience"), "ref": .string(experience.ref), "label": .string(String(experience.label.prefix(120))),
                "origin": .string(experience.origin ?? "settings"), "mode": .string("experience"), "scope": .string(packaged > 0 ? scope : "all"),
            ]
            if let hook = experience.hook { fields["hook"] = .string(hook) }
            if experience.short { fields["short"] = .bool(true) }
            return .object(fields)
        }
        let items: [Item]
        var ref: String?, kind = "topic", origin: String?
        switch plan {
        case .set(let list, _), .practice(let list): items = list
        case .single(let item, let singleRef, let focusKind, let singleOrigin):
            items = [item]; ref = singleRef?.nonEmptyValue; kind = focusKind ?? "topic"; origin = singleOrigin
        default: return nil
        }
        guard let first = items.first else { return nil }
        var fields: [String: JSONValue] = [
            "kind": .string(kind), "ref": .string(ref ?? String("free:\(first.label)".prefix(128))), "label": .string(String(first.label.prefix(120))),
            "origin": .string(origin ?? "settings"), "mode": .string("single"),
            "items": .array(items.map { item in
                var row: [String: JSONValue] = ["label": .string(String(item.label.prefix(120))), "question": .string(String(item.question.prefix(500))),
                                                "signals": strings(item.signals.prefix(5).map { $0 })]
                if let source = item.source { row["source"] = .string(source) }
                return .object(row)
            }),
        ]
        if !first.question.isEmpty { fields["question"] = .string(String(first.question.prefix(500))) }
        return .object(fields)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
