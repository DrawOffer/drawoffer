import Foundation

/// 编辑器右上角的小绘（Web `aiOrbModel.buildOrbDialogue`）：点开后白板上说一句、给编号选项（只有一个推荐）和一行“直接说”。
/// 排版进行中、排版待确认、经历资料三种状态依赖桌面端还没有的智能排版与经历资料，这里只移植两种常态。
public enum ResumeOrb {
    public enum Action: Equatable, Sendable {
        /// 没有光标所在段时：先点纸上一段。
        case pickUnit
        /// 改光标所在的这一段。
        case deepenUnit(String)
        case layout

        public var label: String {
            switch self {
            case .pickUnit: "挑一段来改"
            case .deepenUnit: "改这一段"
            case .layout: "智能排版"
            }
        }
    }

    public struct Dialogue: Equatable, Sendable {
        public let say: String
        public let note: String?
        public let actions: [Action]
        /// 第一项是推荐（蓝字）。
        public var accent: Action? { actions.first }
    }

    public static let note = "改好会先写在纸上，你看过再换上。"
    public static let inputPlaceholder = "或者直接说想改什么…"

    public static func dialogue(unitID: String?, unitLabel: String?) -> Dialogue {
        if let unitID, let unitLabel, !unitLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Dialogue(say: "想改「\(compactUnitName(unitLabel))」的话，我先看看这段，再问你几句当时的情况。", note: note,
                            actions: [.deepenUnit(unitID), .layout])
        }
        return Dialogue(say: "想改哪儿？点纸上任意一段，我就去那一段。", note: note, actions: [.pickUnit, .layout])
    }

    /// 截断过长标签（按字符计，超出加 …）。
    public static func shortLabel(_ label: String, max: Int = 12) -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.count > max ? String(clean.prefix(max)) + "…" : clean
    }

    /// 只取段落的核心名称（「实习经历 · 禾赛科技」→「禾赛科技」），免得前缀吃光宽度。
    public static func compactUnitName(_ label: String, max: Int = 12) -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let parts = clean.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return shortLabel(parts.count > 1 ? parts[parts.count - 1] : clean, max: max)
    }
}
