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
    /// 网申最常问的几项：右上角“还差 N 项”只数这些（再加证件号码）。
    public static let common = ["name", "gender", "birth_date", "phone", "email", "ethnicity", "political_status", "native_place"]
    public static let textKinds: Set<String> = ["skills", "profile", "interests"]
    public static let skillLevels = [("basic", "了解"), ("familiar", "熟悉"), ("proficient", "熟练")]

    public static func missing(_ profile: JSONValue) -> [String] {
        let personal = profile["personal"] ?? .null
        let keys = common.filter { personal.text($0).isEmpty }
        return profile["has_id_number"]?.bool == true ? keys : keys + ["id_number"]
    }

    public static func entryKind(_ kind: String) -> String { ["education", "work", "project"].contains(kind) ? kind : "other" }

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
}
