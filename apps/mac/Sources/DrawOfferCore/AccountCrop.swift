import Foundation

/// 头像裁剪（Web `account/avatarCrop.ts`）：320 视口里 264 的圆窗，图片按 cover 铺满圆窗再乘缩放；
/// 拖动范围限制在图片不露出圆窗。导出时从原图取圆窗对应的正方形，缩到 512。
public enum AvatarCrop {
    public static let output = 512.0
    public static let viewport = 320.0
    public static let window = 264.0
    public static let minZoom = 1.0
    public static let maxZoom = 3.0

    public struct Draft: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var zoom: Double
        public var offsetX: Double
        public var offsetY: Double
        public init(width: Double, height: Double, zoom: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
            self.width = width; self.height = height; self.zoom = zoom; self.offsetX = offsetX; self.offsetY = offsetY
        }
    }

    public struct Layout: Equatable, Sendable {
        public let renderedWidth: Double
        public let renderedHeight: Double
        public let maxOffsetX: Double
        public let maxOffsetY: Double
        public let scale: Double
    }

    public static func layout(_ draft: Draft) -> Layout {
        let scale = max(window / draft.width, window / draft.height) * clampZoom(draft.zoom)
        let width = draft.width * scale, height = draft.height * scale
        return Layout(renderedWidth: width, renderedHeight: height,
                      maxOffsetX: max(0, (width - window) / 2), maxOffsetY: max(0, (height - window) / 2), scale: scale)
    }

    public static func clamp(_ draft: Draft) -> Draft {
        let layout = layout(draft)
        var next = draft
        next.zoom = clampZoom(draft.zoom)
        next.offsetX = min(max(draft.offsetX, -layout.maxOffsetX), layout.maxOffsetX)
        next.offsetY = min(max(draft.offsetY, -layout.maxOffsetY), layout.maxOffsetY)
        return next
    }

    /// 原图里要导出的正方形（左上角为原点）。
    public static func source(_ draft: Draft) -> (x: Double, y: Double, size: Double) {
        let draft = clamp(draft)
        let layout = layout(draft)
        let inset = (viewport - window) / 2
        let left = viewport / 2 - layout.renderedWidth / 2 + draft.offsetX
        let top = viewport / 2 - layout.renderedHeight / 2 + draft.offsetY
        let size = window / layout.scale
        return (min(max((inset - left) / layout.scale, 0), draft.width - size), min(max((inset - top) / layout.scale, 0), draft.height - size), size)
    }

    private static func clampZoom(_ value: Double) -> Double { min(max(value, minZoom), maxZoom) }
}

/// 求职资料页（Web `account/CareerProfilePage.tsx`）里与界面无关的规则。
public enum CareerProfileRules {
    public struct Row: Sendable {
        public let key: String; public let label: String; public let options: [String]?; public let hint: String?
        public init(key: String, label: String, options: [String]?, hint: String?) { self.key = key; self.label = label; self.options = options; self.hint = hint }
    }
    public static let basic = [
        Row(key: "name", label: "姓名", options: nil, hint: nil),
        Row(key: "gender", label: "性别", options: ["男", "女", "其他", "不愿透露"], hint: nil),
        Row(key: "birth_date", label: "出生日期", options: nil, hint: "填到日，例如 2003-05-18；只知道年月就填 2003-05"),
        Row(key: "phone", label: "手机号", options: nil, hint: nil),
        Row(key: "email", label: "邮箱", options: nil, hint: nil),
    ]
    public static let links = [
        Row(key: "github", label: "GitHub", options: nil, hint: "填主页地址或用户名"),
        Row(key: "website", label: "个人网站", options: nil, hint: "以 http:// 或 https:// 开头"),
        Row(key: "portfolio_url", label: "作品集", options: nil, hint: "以 http:// 或 https:// 开头"),
    ]
    public static let identity = [
        Row(key: "ethnicity", label: "民族", options: nil, hint: nil),
        Row(key: "political_status", label: "政治面貌", options: ["中共党员", "中共预备党员", "共青团员", "群众", "其他"], hint: nil),
        Row(key: "native_place", label: "籍贯", options: nil, hint: nil),
        Row(key: "home_city", label: "家庭所在城市", options: nil, hint: nil),
    ]
    /// 网申最常问的几项：右上角“还差 N 项”只数这些（再加证件号码）。
    public static let common = ["name", "gender", "birth_date", "phone", "email", "ethnicity", "political_status", "native_place"]
    public static let entrySupplements: [String: [String]] = ["education": ["gpa", "major_rank", "courses", "study_mode", "advisor"], "work": ["department"], "project": [], "other": []]
    public static let entryFields: [String: [String]] = ["education": ["学校", "专业", "学历学位", "开始时间", "结束时间"], "work": ["单位", "职位", "开始时间", "结束时间"],
                                                        "project": ["项目名称", "角色", "开始时间", "结束时间"], "other": ["名称", "开始时间", "结束时间"]]
    public static let textKinds: Set<String> = ["skills", "profile", "interests"]
    public static let skillLevels = [("basic", "了解"), ("familiar", "熟悉"), ("proficient", "熟练")]

    public static func missing(_ profile: JSONValue) -> [String] {
        let personal = profile["personal"] ?? .null
        let keys = common.filter { personal.text($0).isEmpty }
        return profile["has_id_number"]?.bool == true ? keys : keys + ["id_number"]
    }

    /// 目录里其余“个人”字段（不含网站专属与已展示的）。
    public static func moreRows(_ profile: JSONValue) -> [(key: String, label: String)] {
        let shown = Set((basic + links + identity).map(\.key))
        guard case .object(let fields) = profile["catalog"]?["fields"] ?? .null else { return [] }
        return fields.values.filter { $0.text("scope") == "personal" && $0.text("site").isEmpty && !shown.contains($0.text("key")) && $0.text("key") != "summary" }
            .map { ($0.text("key"), $0.text("label")) }.sorted { $0.key < $1.key }
    }

    public static func entryKind(_ kind: String) -> String { ["education", "work", "project"].contains(kind) ? kind : "other" }

    public struct Item: Sendable { public let sectionIndex: Int; public let entry: JSONValue; public let kind: String }
    public struct Group: Sendable { public let key: String; public let label: String; public var items: [Item] }

    public static func groups(_ experience: JSONValue) -> [Group] {
        var result = [("education", "教育"), ("internship", "实习"), ("work", "工作"), ("project", "项目"), ("campus", "校园"), ("other", "奖项与证书")].map { Group(key: $0.0, label: $0.1, items: []) }
        for (index, section) in (experience["sections"]?.items ?? []).enumerated() {
            let raw = section.text("kind")
            if textKinds.contains(raw) { continue }
            let kind = entryKind(raw)
            for entry in section["entries"]?.items ?? [] {
                let key = kind == "work" ? (entry["intern"]?.bool == true ? "internship" : "work") : raw == "activity" ? "campus" : kind
                if let position = result.firstIndex(where: { $0.key == key }) { result[position].items.append(Item(sectionIndex: index, entry: entry, kind: kind)) }
            }
        }
        return result.filter { !$0.items.isEmpty }
    }

    public static func entryTitle(_ entry: JSONValue) -> String {
        let fields = entry["fields"] ?? .null
        for key in ["学校", "单位", "所属单位", "项目名称", "名称"] where !fields.text(key).isEmpty { return fields.text(key) }
        if case .object(let all) = fields, let first = all.keys.sorted().first, let value = all[first]?.stringValue, !value.isEmpty { return value }
        return "未命名"
    }

    /// 技能：已标熟练度的列表；还没有时从简历技能行里拆出名字（未标注）。
    public static func skills(_ experience: JSONValue?) -> [(name: String, level: String?)] {
        let existing = experience?["skills"]?.items ?? []
        if !existing.isEmpty { return existing.map { ($0.text("name"), $0.text("level").nonEmptyValue) } }
        var names: [(String, String?)] = [], seen = Set<String>()
        for section in experience?["sections"]?.items ?? [] where section.text("kind") == "skills" {
            let lines = (section["lines"]?.items ?? []).compactMap(\.stringValue) + (section["entries"]?.items ?? []).map { entry in
                guard case .object(let fields) = entry["fields"] ?? .null else { return "" }
                return fields.keys.sorted().compactMap { fields[$0]?.stringValue }.joined(separator: "、")
            }
            for line in lines {
                for part in line.components(separatedBy: CharacterSet(charactersIn: "；;")) {
                    let text = part.replacingOccurrences(of: #"^[^：:]{1,12}[：:]"#, with: "", options: .regularExpression)
                    for raw in text.components(separatedBy: CharacterSet(charactersIn: "、,，/|")) {
                        let name = raw.replacingOccurrences(of: #"^[-•·\s]+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, name.count <= 60, seen.insert(name.lowercased()).inserted { names.append((name, nil)) }
                    }
                }
            }
        }
        return Array(names.prefix(60))
    }

    public static func salaryText(_ intent: JSONValue) -> String {
        let values = [intent["salary_min"]?.numberValue, intent["salary_max"]?.numberValue].compactMap { $0 }
        guard !values.isEmpty else { return "" }
        return values.map { "\(Int(($0 / 1000).rounded()))K" }.joined(separator: "–") + " / " + (intent.text("salary_period") == "year" ? "年" : "月")
    }
}
