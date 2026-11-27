import Foundation

/// 站内消息（`GET /api/notifications`，Web `UserNotification`）：面试提醒、复盘、记忆提示、后台任务结果、反馈处理结果。
public struct InboxMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: String
    public let title: String
    public let body: String
    public let link: String
    public var read: Bool
    public let createdAt: Date?

    public init(json: JSONValue) {
        id = json.text("id"); category = json.text("category"); title = json.text("title")
        body = json.text("body"); link = json.text("link"); read = json["read"]?.bool ?? false
        createdAt = ISO8601DateFormatter.flexible(json.text("createdAt"))
    }

    /// 与 Web `notificationCategoryLabel` 一致。
    public var categoryLabel: String {
        switch category {
        case "interview": "面试提醒"
        case "review": "面试复盘"
        case "peak", "insight": "长期记忆"
        case "idle": "练习提醒"
        case "task": "处理结果"
        case "feedback": "问题反馈"
        default: "消息"
        }
    }

    /// 处理结果与反馈蓝、面试提醒橙，其余灰（Web `.ann-item-category[data-tone]`）。
    public var tone: String {
        switch category {
        case "task", "feedback": "blue"
        case "interview": "orange"
        default: "muted"
        }
    }

    /// 只认站内单斜杠路径（Web `safeNotificationLink`），不接受协议或 `//host`。
    public var safeLink: String? {
        let value = link.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("/"), !value.hasPrefix("//"), !value.hasPrefix("/\\") else { return nil }
        return value
    }

    /// 反馈送了积分：Web 进个人设置并打开额度弹窗的积分页。
    public var opensCredits: Bool { category == "feedback" && safeLink == "/account#credits" }

    /// 从用户角度说点开去哪（Web `messageAction`）；没有可去的页面时不显示。
    public var action: String? {
        guard let link = safeLink else { return nil }
        switch category {
        case "task":
            if link.range(of: #"/report(?:[?#]|$)"#, options: .regularExpression) != nil { return "查看报告" }
            return link.hasPrefix("/career/reviews") ? "查看复盘" : "去看看"
        case "feedback": return "查看积分"
        case "interview": return "去准备"
        case "review": return "去复盘"
        default: return "去看看"
        }
    }
}

/// 反馈页（Web `features/feedback/FeedbackPage.tsx`）：表单状态、校验、请求体与错误文案。
public struct FeedbackDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case bug, idea, other
        public var label: String {
            switch self {
            case .bug: "遇到问题"
            case .idea: "功能建议"
            case .other: "其他"
            }
        }
    }

    public enum Occurred: String, CaseIterable, Sendable {
        case justNow = "just_now", today, earlier
        public var label: String {
            switch self {
            case .justNow: "刚刚"
            case .today: "今天"
            case .earlier: "更早"
            }
        }
    }

    /// 存为 `pageName`，管理端原样显示。
    public static let features = ["简历编辑器", "AI 对话", "模拟面试", "面试复盘", "求职记录", "岗位广场", "资料库", "浏览器插件", "小程序", "账号与积分", "其他"]
    public static let maxShots = 3
    public static let titleLimit = 100
    public static let contentLimit = 2000
    public static let contactLimit = 128
    /// 超过这个大小的截图先缩成不超过 2000 px 宽的 JPEG 再发（后端每张解码后 ≤ 5 MB）。
    public static let maxShotBytes = 4_500_000

    public var kind: Kind = .bug
    public var feature = ""
    public var title = ""
    public var content = ""
    public var occurred: Occurred?
    public var contact = ""
    /// data URL。
    public var shots: [String] = []

    public init() {}

    public var placeholder: String { kind == .bug ? "1. 做了什么操作\n2. 期望看到什么\n3. 实际看到了什么" : "希望多一个什么功能，或者哪里用着不顺手？" }

    /// 选了涉及功能、写了一句话说明和详细描述才能提交。
    public var ready: Bool { !feature.isEmpty && !title.trimmed.isEmpty && !content.trimmed.isEmpty }

    /// `POST /api/feedback` 的请求体。后端 `client` 只认 web / miniprogram，桌面端按 web 发，`clientVersion` 写明是 Mac 客户端。
    public func body(signedIn: Bool, clientVersion: String) -> JSONValue {
        .object([
            "kind": .string(kind.rawValue),
            "title": .string(String(title.trimmed.prefix(Self.titleLimit))),
            "content": .string(String(content.trimmed.prefix(Self.contentLimit))),
            "screenshots": .array(shots.prefix(Self.maxShots).map(JSONValue.string)),
            "pagePath": .string(""),
            "pageName": .string(feature),
            "occurred": .string(occurred?.rawValue ?? ""),
            "contact": .string(signedIn ? "" : String(contact.trimmed.prefix(Self.contactLimit))),
            "client": .string("web"),
            "clientVersion": .string(String(clientVersion.prefix(64))),
        ])
    }

    /// 提交失败的提示（Web 同名文案）；桌面会话被拒时说清楚，给出进群这条路。
    public static func errorText(_ error: Error) -> String {
        if case APIError.server(let status, let code) = error {
            if code == "FEEDBACK_RATE_LIMITED" { return "今天提交得有点多了，明天再来，或者直接进群说" }
            if code == "IMAGE_TOO_LARGE" { return "截图太大了，换一张小一点的" }
            if code == "INVALID_IMAGE" { return "截图读取失败，换一张试试" }
            if status == 403 || code == "DESKTOP_ROUTE_FORBIDDEN" { return "桌面端暂时还不能提交反馈，可以先进群说，或到网页版反馈" }
        }
        if case APIError.unauthorized = error { return "登录已失效，请重新登录后再提交" }
        return "提交失败，请稍后再试"
    }

    /// 页脚说明（Web `.fb-foot small`）。
    public static func footnote(signedIn: Bool, nickname: String) -> String {
        signedIn ? "以 \(nickname) 的账号提交 · 系统和客户端版本会一并发送" : "将匿名提交 · 系统和客户端版本会一并发送"
    }
}

/// 交流群邀请链接（`GET /api/community-groups`）；只认 http(s)，未设置为 nil。
public struct CommunityGroups: Equatable, Sendable {
    public let qq: String?
    public let wechat: String?

    public init(json: JSONValue) {
        func link(_ key: String) -> String? {
            let value = json.text(key).trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("https://") || value.hasPrefix("http://") ? value : nil
        }
        qq = link("qq"); wechat = link("wechat")
    }

    public var isEmpty: Bool { qq == nil && wechat == nil }
    public var both: Bool { qq != nil && wechat != nil }
    /// 选中的群没有链接时退到另一个（Web 默认 QQ，只有微信时选微信）。
    public func current(_ pick: String) -> (key: String, link: String)? {
        if pick == "wechat", let wechat { return ("wechat", wechat) }
        if let qq { return ("qq", qq) }
        return wechat.map { ("wechat", $0) }
    }
}

/// 反馈与交流群接口：公开路由，桌面会话照常带凭据。
public enum FeedbackRequest {
    public static func allowed(path: String, method: String) -> Bool {
        (path == "/api/feedback" && method == "POST") || (path == "/api/community-groups" && method == "GET")
    }
}
