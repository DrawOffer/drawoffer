import Foundation

/// 岗位广场（Web `features/jobs/OpportunitiesPage.tsx` 与 `jobPoolPresentation.ts`）的展示规则：
/// 招聘类型、列表时间、官网发布时间与岗位正文分段。
public enum JobPool {
    /// 岗位广场只提供校招和实习（后端 `OFFERED_BUCKETS`）。
    public static let types: [(value: String, label: String)] = [("campus", "校招"), ("internship", "实习")]
    public static let sorts: [(value: String, label: String)] = [("open", "在招最多"), ("today", "今日新增最多"), ("latest", "最近更新"), ("name", "按名称")]
    public static let keywordError = "关键词需要包含 2～100 个字符。"

    /// `poolRecruitment`.
    public static func recruitment(_ job: JSONValue) -> String {
        if job.text("employment_type") == "internship" { return "实习" }
        switch job.text("recruitment_channel") {
        case "campus": return "校招"
        case "experienced": return "社招"
        default: return "招聘类型未标明"
        }
    }

    /// 详情事实里的「招聘类型」：渠道 · 用工形式，未知项省略。
    public static func jobType(_ job: JSONValue) -> String {
        let channel = ["campus": "校招", "experienced": "社招"][job.text("recruitment_channel")]
        let employment = ["internship": "实习", "full_time": "正式", "part_time": "兼职", "contract": "合同制"][job.text("employment_type")]
        return [channel, employment].compactMap { $0 }.joined(separator: " · ")
    }

    public static func cities(_ job: JSONValue) -> [String] {
        (job["locations"]?["cities"]?.items ?? []).compactMap(\.stringValue)
    }

    public static func attribute(_ job: JSONValue, _ key: String) -> String? {
        job["source_attributes"]?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue
    }

    public static func isToday(_ value: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date = CareerApplication.date(value) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    /// `poolRelative`：今天 / N 天前 / N 周前，之后为「10月29日」，非今年带年份。
    public static func relative(_ value: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "今天" }
        if days < 7 { return "\(days) 天前" }
        if days < 28 { return "\(days / 7) 周前" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year == calendar.component(.year, from: now) ? "" : "\(parts.year ?? 0)年"
        return "\(year)\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// `poolDate`：今天 / 昨天 / 2026/10/29，后接 24 小时制时间。
    public static func date(_ value: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = CareerApplication.date(value) else { return "尚无记录" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = calendar.isDate(date, inSameDayAs: now) ? "今天"
            : calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } == true ? "昨天"
            : "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
        return "\(day) \(CareerDeckFormat.clock(date, calendar: calendar))"
    }

    /// 列表行的元信息：城市、招聘类型、方向、薪资、发布时间。
    public static func meta(_ job: JSONValue, now: Date = Date()) -> [String] {
        [cities(job).joined(separator: "、").nonEmptyValue ?? "地点未标明", recruitment(job), job.text("category"), job.text("salary_text"),
         relative(job.text("published_at"), now: now)].filter { !$0.isEmpty }
    }

    public static func host(_ url: String) -> String { URL(string: url)?.host() ?? url }

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

    // MARK: 岗位正文

    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case points([String])
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        public let blocks: [Block]
    }

    private static let headings = ["团队介绍", "部门介绍", "工作职责", "岗位职责", "职位描述", "岗位描述", "任职要求", "岗位要求", "职位要求", "加分项", "工作地点"]
    private static let point = try! NSRegularExpression(pattern: #"^\s*(?:\d{1,2}\s*[.、．)）]|[-•·*])\s*"#)

    /// `JobBody`：已知小标题开新段，编号或项目符号行归为对齐的要点；没有正文时返回空数组。
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
