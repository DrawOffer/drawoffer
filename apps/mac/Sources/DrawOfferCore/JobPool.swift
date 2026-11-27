import Foundation

/// 岗位广场（Web `features/jobs/OpportunitiesPage.tsx`、`PoolFilterPanel.tsx` 与 `jobPoolPresentation.ts`）的展示规则：
/// 招聘类型、列表时间、筛选条件与查询参数、筛选弹层的城市与方向、意向说明、投递截止与岗位正文分段。
public enum JobPool {
    /// 岗位广场只提供校招和实习（后端 `OFFERED_BUCKETS`）。
    public static let types: [(value: String, label: String)] = [("campus", "校招"), ("internship", "实习")]
    public static let withins: [(value: String, label: String)] = [("", "不限"), ("today", "今日新增"), ("3d", "近 3 天"), ("7d", "近 7 天"), ("30d", "近 30 天")]
    public static let sorts: [(value: String, label: String)] = [("recommend", "综合"), ("published", "最新发布")]
    public static let keywordError = "关键词需要包含 2～100 个字符。"
    /// 筛选弹层默认露出的城市与方向个数，其余收在「更多」里。
    public static let hotCities = 9
    public static let shownCategories = 9
    /// 按公司看时每页的公司数（Web `COMPANY_PAGE_SIZE`）。
    public static let companyPageSize = 21
    /// 方向按常见程度排，其余按名称跟在后面。
    static let categoryOrder = ["研发", "技术", "产品", "设计", "运营", "市场与销售", "职能", "生产与制造", "质量", "供应链"]

    /// `poolRecruitment`.
    public static func recruitment(_ job: JSONValue) -> String {
        if job.text("employment_type") == "internship" { return "实习" }
        switch job.text("recruitment_channel") {
        case "campus": return "校招"
        case "experienced": return "社招"
        default: return "招聘类型未标明"
        }
    }

    /// 详情标签里的「招聘类型」：渠道 · 用工形式，未知项省略。
    public static func jobType(_ job: JSONValue) -> String {
        let channel = ["campus": "校招", "experienced": "社招"][job.text("recruitment_channel")]
        let employment = ["internship": "实习", "full_time": "正式", "part_time": "兼职", "contract": "合同制"][job.text("employment_type")]
        return [channel, employment].compactMap { $0 }.joined(separator: " · ")
    }

    public static func cities(_ job: JSONValue) -> [String] {
        (job["locations"]?["cities"]?.items ?? []).compactMap(\.stringValue)
    }

    /// `cityLabel`：卡片上最多写三个城市，再多就省略，免得一行地点把摘要和操作挤变形。
    public static func cityLabel(_ cities: [String], limit: Int = 3) -> String {
        let names = cities.filter { !$0.isEmpty }
        if names.isEmpty { return "地点未标明" }
        return names.count > limit ? names.prefix(limit).joined(separator: "、") + "…" : names.joined(separator: "、")
    }

    public static func attribute(_ job: JSONValue, _ key: String) -> String? {
        job["source_attributes"]?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue
    }

    public static func isToday(_ value: String, now: Date = Date(), calendar: Calendar = Beijing.calendar) -> Bool {
        guard let date = CareerApplication.date(value) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    /// `poolRelative`：今天 / N 天前 / N 周前，之后为「10月29日」，非今年带年份。
    public static func relative(_ value: String, now: Date = Date(), calendar: Calendar = Beijing.calendar) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "今天" }
        if days < 7 { return "\(days) 天前" }
        if days < 28 { return "\(days / 7) 周前" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year == calendar.component(.year, from: now) ? "" : "\(parts.year ?? 0)年"
        return "\(year)\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// 今天 / 昨天 / 2026/10/29，后接 24 小时制时间（公司页「HH:mm 同步」用）。
    public static func date(_ value: String, now: Date = Date(), calendar: Calendar = Beijing.calendar) -> String {
        guard let date = CareerApplication.date(value) else { return "尚无记录" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = calendar.isDate(date, inSameDayAs: now) ? "今天"
            : calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } == true ? "昨天"
            : "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
        return "\(day) \(CareerDeckFormat.clock(date, calendar: calendar))"
    }

    public static func host(_ url: String) -> String { URL(string: url)?.host() ?? url }

    /// 千分位（Web `toLocaleString("zh-CN")`）。
    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// `poolError` 中工作区会遇到的错误码。
    public static func error(_ code: String) -> String {
        [
            "JOB_POOL_CLOSED": "该岗位已下线，无法新加入求职进程。",
            "JOB_POOL_NOT_FOUND": "未找到该岗位。",
            "JOB_POOL_INVALID_QUERY": "关键词需要包含 2～100 个字符。",
            "JOB_POOL_INVALID_CURSOR": "筛选条件已变化，请重新搜索。",
            "JOB_POOL_SOURCE_CONFLICT": "同一官网岗位已关联其他共享岗位，请打开现有求职记录。",
        ][code] ?? "操作未完成，请重试。"
    }

    // MARK: 查询参数

    /// 一个参数带多个值（城市、方向可多选，后端按任一命中）时用换行拼成一个值，发请求时再拆成重复的同名参数。
    /// 城市与方向名不含换行；值去重排序，与 Web `poolQueryParams` 一样同一组条件得到同一个缓存键。
    public static let multiSeparator: Character = "\n"

    public static func multi(_ values: [String]) -> String {
        Array(Set(values.filter { !$0.isEmpty })).sorted().joined(separator: String(multiSeparator))
    }

    public static func queryItems(_ query: [String: String]) -> [URLQueryItem] {
        query.sorted { $0.key < $1.key }.flatMap { key, value in
            value.contains(multiSeparator)
                ? value.split(separator: multiSeparator).map { URLQueryItem(name: key, value: String($0)) }
                : [URLQueryItem(name: key, value: value)]
        }
    }

    /// 推荐流的随机种子（后端要求 1–32 位字母数字）：同一种子翻页顺序不变，重新进入广场才换一批。
    public static func newSeed() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    /// 按公司看的下一页：已取到的公司数不足总数时才有。
    public static func nextPage(_ page: Int, pageSize: Int, total: Int) -> Int? { page * pageSize < total ? page + 1 : nil }

    public static func sortCategories(_ names: [String]) -> [String] {
        func rank(_ name: String) -> Int { categoryOrder.firstIndex(of: name) ?? categoryOrder.count }
        return names.filter { !$0.isEmpty }.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.compare($1, locale: Locale(identifier: "zh-Hans-CN")) == .orderedAscending
        }
    }

    // MARK: 筛选弹层

    /// 弹层里的城市：搜索时只列名字含输入的；展开时全部；平时列出最热的 9 个，已选但不在其中的排在前面。
    /// `order` 是弹层打开后第一次拿到的城市顺序，之后换方向、时间只改数字，城市不跳动、不消失。
    public static func panelCities(order: [String]?, counted: [String], picked: [String], needle: String, all: Bool) -> [String] {
        let fixed = order ?? []
        let known = fixed + counted.filter { !fixed.contains($0) }
        var named: [String] = []
        for name in known + picked where !named.contains(name) { named.append(name) }
        if !needle.isEmpty { return named.filter { $0.contains(needle) } }
        if all { return named }
        let hot = Array(fixed.prefix(hotCities))
        return picked.filter { !hot.contains($0) } + hot
    }

    public static func hasMoreCities(order: [String]?, needle: String) -> Bool { needle.isEmpty && (order?.count ?? 0) > hotCities }

    public static func panelCategories(_ categories: [String], picked: [String], all: Bool) -> [String] {
        if all { return categories }
        let head = Array(categories.prefix(shownCategories))
        return head + picked.filter { !head.contains($0) }
    }

    // MARK: 关键词高亮

    /// `HighlightTerms`：把文本按关键词（空格分开，最多 6 个，长词优先）切成命中与未命中的片段；1–3 个英文字母只按整词命中。
    public static func highlight(_ text: String, keyword: String) -> [(text: String, hit: Bool)] {
        var terms: [String] = []
        for term in keyword.split(whereSeparator: \.isWhitespace).map(String.init) where !terms.contains(term) { terms.append(term) }
        terms = Array(terms.prefix(6))
        guard !terms.isEmpty, !text.isEmpty else { return [(text, false)] }
        let pattern = terms.sorted { $0.count > $1.count }.map { term in
            let escaped = NSRegularExpression.escapedPattern(for: term)
            return term.range(of: "^[A-Za-z]{1,3}$", options: .regularExpression) != nil ? "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])" : escaped
        }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [(text, false)] }
        var parts: [(String, Bool)] = [], last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), !range.isEmpty else { continue }
            if last < range.lowerBound { parts.append((String(text[last..<range.lowerBound]), false)) }
            parts.append((String(text[range]), true)); last = range.upperBound
        }
        if last < text.endIndex { parts.append((String(text[last...]), false)) }
        return parts.isEmpty ? [(text, false)] : parts
    }

    // MARK: 投递截止

    public enum Deadline: Equatable, Sendable {
        case past(String), today, left(String, days: Int)
    }

    /// `Deadline`：`YYYY-MM-DD` 与北京时间今天比，「11月30日截止，还剩 48 天」；非今年带年份。
    public static func deadline(_ value: String, now: Date = Date(), calendar: Calendar = Beijing.calendar) -> Deadline? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 > 0 }),
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
        let text = (parts[0] == calendar.component(.year, from: now) ? "" : "\(parts[0])年") + "\(parts[1])月\(parts[2])日"
        return days < 0 ? .past(text) : days == 0 ? .today : .left(text, days: days)
    }

    // MARK: 岗位正文

    public struct Pair: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case points([String])
        case pairs([Pair])
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        public let blocks: [Block]
    }

    private static let headings = ["团队介绍", "部门介绍", "工作职责", "岗位职责", "职位描述", "岗位描述", "任职要求", "岗位要求", "职位要求", "加分项", "工作地点"]
    private static let point = try! NSRegularExpression(pattern: #"^\s*(?:\d{1,2}\s*[.、．)）]|[-•·*])\s*"#)

    /// `JobBody`：有 `description_sections` 时按它分段（要点、键值行、段落），否则从正文文本里按已知小标题拆；没有正文时返回空数组。
    public static func body(_ job: JSONValue) -> [Section] {
        guard case .object = job["description_sections"] ?? .null else { return sections(job.text("description")) }
        return (job["description_sections"]?["sections"]?.items ?? []).compactMap { section in
            let items = section["items"]?.items ?? []
            guard !items.isEmpty else { return nil }
            var blocks: [Block] = [], points: [String] = [], pairs: [Pair] = []
            func flushPoints() { if !points.isEmpty { blocks.append(.points(points)); points = [] } }
            func flushPairs() { if !pairs.isEmpty { blocks.append(.pairs(pairs)); pairs = [] } }
            for item in items {
                switch item.text("type") {
                case "list": flushPairs(); points.append(item.text("text"))
                case "kv": flushPoints(); pairs.append(Pair(item.text("label"), item.text("value")))
                default: flushPoints(); flushPairs(); blocks.append(.paragraph(item.text("text")))
                }
            }
            flushPoints(); flushPairs()
            return Section(title: section.text("title"), blocks: blocks)
        }
    }

    /// 旧数据（正文还没分段）的纯文本拆法：已知小标题开新段，编号或项目符号行归为对齐的要点。
    public static func sections(_ text: String) -> [Section] {
        var raw: [(title: String, lines: [String])] = []
        for line in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let heading = headings.first(where: { line.hasPrefix($0) }) {
                var rest = line.dropFirst(heading.count)
                if rest.first == ":" || rest.first == "：" { rest = rest.dropFirst() }
                let body = rest.trimmingCharacters(in: .whitespaces)
                // 与 Web 正则 `^(小标题)[:：]?\s*(.*)$` 相同：同行内容短于 120 字才算小标题。
                if body.utf16.count < 120 { raw.append((heading, body.isEmpty ? [] : [body])); continue }
            }
            if raw.isEmpty { raw.append(("岗位描述", [])) }
            if !line.isEmpty { raw[raw.count - 1].lines.append(line) }
        }
        return raw.filter { !$0.lines.isEmpty }.map { section in
            var blocks: [Block] = [], points: [String] = []
            func flush() { if !points.isEmpty { blocks.append(.points(points)); points = [] } }
            for line in section.lines {
                let range = NSRange(line.startIndex..., in: line)
                if let match = point.firstMatch(in: line, range: range), let end = Range(match.range, in: line) {
                    points.append(String(line[end.upperBound...]))
                } else { flush(); blocks.append(.paragraph(line)) }
            }
            flush()
            return Section(title: section.title, blocks: blocks)
        }
    }
}

/// 筛选弹层里选的条件（Web `PoolPanelValue`）：点「查看 N 个岗位」才生效，弹层里改的只是草稿。
public struct PoolPanel: Hashable, Sendable {
    public var cities: [String] = []
    public var categories: [String] = []
    /// "" / today / 3d / 7d / 30d
    public var within = ""
    /// recommend（综合）/ published（最新发布）
    public var sort = "recommend"
    public var excludeJoined = false
    public init() {}
    public static let empty = PoolPanel()

    public var query: [String: String] {
        var query: [String: String] = [:]
        if !cities.isEmpty { query["city"] = JobPool.multi(cities) }
        if !categories.isEmpty { query["job_category"] = JobPool.multi(categories) }
        if !within.isEmpty { query["published_within"] = within }
        if excludeJoined { query["exclude_joined"] = "true" }
        return query
    }

    public func toggled(city: String) -> PoolPanel { var next = self; next.cities = Self.toggle(cities, city); return next }
    public func toggled(category: String) -> PoolPanel { var next = self; next.categories = Self.toggle(categories, category); return next }
    static func toggle(_ list: [String], _ item: String) -> [String] { list.contains(item) ? list.filter { $0 != item } : list + [item] }
}

/// 岗位广场当前的全部条件（Web `PlazaState`）：类型、弹层条件、关键词、意向与看法；两种看法共用同一组筛选。
public struct PoolPlaza: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable { case job, company }
    public var panel = PoolPanel()
    /// "" / campus / internship
    public var type = ""
    public var q = ""
    public var intent = false
    public var mode: Mode = .job
    public init() {}

    /// 一个字还在输入中：服务端只搜两个字以上，最多 100 字。
    public static func keyword(_ typed: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 2 ? String(text.prefix(100)) : ""
    }

    /// 弹层之外、计数仍要遵守的条件：关键词、类型 tab 与意向。
    public func base(keyword: String) -> [String: String] {
        var query: [String: String] = [:]
        if !keyword.isEmpty { query["keyword"] = keyword }
        if !type.isEmpty { query["recruitment_type"] = type }
        if intent { query["intent"] = "true" }
        return query
    }

    /// `/api/job-pool/count` 与 `/api/job-pool/by-company` 的条件。
    public func filter(keyword: String) -> [String: String] { base(keyword: keyword).merging(panel.query) { $1 } }

    /// 搜索时「综合」改按相关度排。
    public func listSort(keyword: String) -> String { !keyword.isEmpty && panel.sort == "recommend" ? "relevance" : panel.sort }

    /// `/api/job-pool` 的条件：筛选 + 排序，推荐流带种子，翻页带游标。
    public func listQuery(keyword: String, seed: String, cursor: String? = nil) -> [String: String] {
        var query = filter(keyword: keyword)
        let sort = listSort(keyword: keyword)
        query["sort"] = sort
        if sort == "recommend" { query["seed"] = seed }
        if let cursor { query["cursor"] = cursor }
        return query
    }

    public var filtered: Bool {
        !panel.cities.isEmpty || !panel.categories.isEmpty || !panel.within.isEmpty || panel.excludeJoined
            || !q.trimmingCharacters(in: .whitespaces).isEmpty || !type.isEmpty || intent
    }

    /// 筛选按钮上的字：「北京、上海 · 研发、产品」；只选了时间、排序等时为「筛选 · N 项」。
    public var filterLabel: String {
        func short(_ list: [String], _ unit: String) -> String {
            list.count > 2 ? "\(list.prefix(2).joined(separator: "、")) 等 \(list.count) \(unit)" : list.joined(separator: "、")
        }
        let named = [short(panel.cities, "城"), short(panel.categories, "个方向")].filter { !$0.isEmpty }.joined(separator: " · ")
        let others = [!panel.within.isEmpty, panel.sort != "recommend", panel.excludeJoined].filter { $0 }.count
        return !named.isEmpty ? named : others > 0 ? "筛选 · \(others) 项" : "筛选"
    }

    /// 空结果插图里搜索框的字。
    public var emptySummary: String {
        let type = JobPool.types.first { $0.value == self.type }?.label ?? ""
        return ([q.trimmingCharacters(in: .whitespaces)] + panel.cities + panel.categories + [type]).filter { !$0.isEmpty }.joined(separator: " · ").nonEmptyValue ?? "筛选"
    }

    /// 清除筛选：类型、关键词、意向和弹层条件都回到默认，看法不变。
    public func cleared() -> PoolPlaza { var next = PoolPlaza(); next.mode = mode; return next }

    /// 从按公司看点进公司页时带过去的条件：公司页只按一个城市、一个方向筛，恰好选了一个时才带。
    public func carry(keyword: String) -> (keyword: String, city: String, category: String, type: String) {
        (keyword, panel.cities.count == 1 ? panel.cities[0] : "", panel.categories.count == 1 ? panel.categories[0] : "", type)
    }
}

/// 「只看符合我意向的」读到的求职画像（`/api/job-pool/count` 的 `intent`）。
public struct PoolIntent: Equatable, Sendable {
    /// ready / signed_out / missing_role
    public let state: String
    /// 「研发 · 上海、杭州 · 校招」：方向、期望城市、求职类型，都没有时写目标岗位。
    public let summary: String
    /// 画像是否完整可按匹配度排序的说明；服务端没给时为 nil。
    public let tip: String?

    public init(_ value: JSONValue?) {
        let value = value ?? .object(["state": .string("signed_out")])
        state = value.text("state").nonEmptyValue ?? "signed_out"
        guard state == "ready" else { summary = ""; tip = nil; return }
        let strings = { (key: String) in (value[key]?.items ?? []).compactMap(\.stringValue) }
        let types = strings("types").map { ["campus": "校招", "internship": "实习"][$0] ?? $0 }
        summary = [value.text("category"), strings("cities").joined(separator: "、"), types.joined(separator: "、")]
            .filter { !$0.isEmpty }.joined(separator: " · ").nonEmptyValue ?? value.text("target_role")
        switch value["profile_ready"] {
        case .bool(true)?: tip = "已结合求职画像优先展示最匹配岗位"
        case .bool(false)?:
            let missing = (value["missing"]?.items ?? []).map { $0.text("label") }.filter { !$0.isEmpty }
            tip = missing.isEmpty ? "补全求职画像后可按匹配度优先排序" : "补全\(missing.joined(separator: "、"))后可按匹配度优先排序"
        default: tip = nil
        }
    }

    public var ready: Bool { state == "ready" }
}
