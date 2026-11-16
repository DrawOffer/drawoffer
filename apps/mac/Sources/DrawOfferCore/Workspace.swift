import Foundation

/// 与后端 `DESKTOP_WORKSPACE_ROUTES` 对齐的桌面白名单：Web 工作区里客户端也要调用的接口。
/// 每项是方法加完整路径正则；不在表内的路径在客户端就被拒绝，不会发出请求。
public enum ParityRequest {
    private static let routes: [(Set<String>, NSRegularExpression)] = [
        (["GET"], #"/api/announcements"#),
        (["GET"], #"/api/announcements/unread-count"#),
        (["POST"], #"/api/announcements/read-all"#),
        (["DELETE"], #"/api/announcements/[A-Za-z0-9_-]{1,64}"#),
        (["GET"], #"/api/notifications(/unread-count|/preferences)?"#),
        (["PUT"], #"/api/notifications/preferences"#),
        (["POST"], #"/api/notifications/(read-all|[A-Za-z0-9_-]{1,64}/(read|open))"#),
        (["DELETE"], #"/api/notifications/[A-Za-z0-9_-]{1,64}"#),
        (["GET", "POST"], #"/api/account/api-keys"#),
        (["DELETE"], #"/api/account/api-keys/[1-9][0-9]{0,19}"#),
        (["GET"], #"/api/billing/(summary|ledger|feature-prices|invite-code|invite-rewards)"#),
        (["POST"], #"/api/billing/invite-codes/check"#),
        (["GET"], #"/api/memory/(home|home/graph|atlas|outline|overview|brief|match-evidence|checkins|constraints|review-links|review-repeats|review-comparison|feedback)"#),
        (["POST"], #"/api/memory/(home/disclosures|checkins|constraints)"#),
        (["DELETE"], #"/api/memory/constraints/[A-Za-z0-9_-]{1,64}"#),
        (["GET"], #"/api/job-pool(/filters|/companies|/companies/page|/companies/[1-9][0-9]{0,19}|/[1-9][0-9]{0,19})?"#),
        (["POST"], #"/api/job-pool/[1-9][0-9]{0,19}/join"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: "^" + $0.1 + "$")) }

    public static func allowed(path: String, method: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return routes.contains { $0.0.contains(method) && $0.1.firstMatch(in: path, range: range) != nil }
    }
}

/// 公告（Web `features/announcements`）：列表、未读数与“全部已读”。
public struct Announcement: Identifiable, Equatable, Sendable {
    public let id: String
    public let important: Bool
    public let category: String
    public let title: String
    public let body: String
    public let publishedAt: Date?
    public let read: Bool

    public init(json: JSONValue) {
        id = json.text("id")
        important = json.text("level") == "important"
        category = json.text("category")
        title = json.text("title")
        body = json.text("body")
        publishedAt = ISO8601DateFormatter.flexible(json.text("publishedAt"))
        read = json["read"]?.bool ?? false
    }

    public var categoryLabel: String {
        switch category {
        case "product_update": "产品更新"
        case "service_notice": "服务通知"
        case "promotion": "活动福利"
        default: "公告"
        }
    }

    public var categorySymbol: String {
        switch category {
        case "service_notice": "megaphone"
        case "promotion": "gift"
        default: "paperplane"
        }
    }

    /// 与 Web `announcementDate` 相同：“10 月 19 日”。
    public var dateText: String {
        guard let publishedAt else { return "" }
        let parts = Beijing.calendar.dateComponents([.month, .day], from: publishedAt)
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    }

    /// 与 Web `announcementPlainText` 一致的单行摘要：去掉 Markdown 标记并折叠空白。
    public var summary: String {
        var text = body
        for pattern in [#"\[([^\]]*)\]\([^)]*\)"#: "$1", #"[*_`>#~]+"#: "", #"^\s*[-+]\s+"#: "", #"^\s*\d+\.\s+"#: ""].sorted(by: { $0.key < $1.key }) {
            text = text.replacingOccurrences(of: pattern.key, with: pattern.value, options: .regularExpression)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct AnnouncementList: Sendable {
    public let items: [Announcement]
    public let unreadCount: Int
    public init(json: JSONValue) {
        items = (json["items"]?.items ?? []).map(Announcement.init)
        if case .number(let count) = json["unreadCount"] { unreadCount = Int(count) } else { unreadCount = 0 }
    }
}

/// 额度摘要（`GET /api/billing/summary`）：侧栏个人菜单只展示档位和可用积分。
public struct BillingSummary: Equatable, Sendable {
    public let tier: String
    public let available: String

    public init(json: JSONValue) {
        let tier = json.text("tier"); self.tier = tier.isEmpty ? "none" : tier
        available = json.display("available")
    }

    public var tierLabel: String {
        switch tier {
        case "basic": "基础会员"
        case "advanced": "进阶会员"
        case "premium": "高级会员"
        default: "免费版"
        }
    }

    /// 与 Web `formatCredits` 一致：最多两位小数、千分位，负数保留负号。
    public var availableText: String { Self.credits(available) }
    public var exhausted: Bool { (Double(available) ?? 0) <= 0 }

    public static func credits(_ value: String) -> String {
        guard let number = Double(value), number.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US")
        let text = formatter.string(from: NSNumber(value: abs(number))) ?? "—"
        return number < 0 ? "-" + text : text
    }
}

extension ISO8601DateFormatter {
    static func flexible(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
