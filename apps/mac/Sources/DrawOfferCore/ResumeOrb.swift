import Foundation

/// 编辑器右上角的小绘（Web `aiOrbModel.buildOrbDialogue`）：点开后白板上说一句、给编号选项（只有一个推荐）和一行“直接说”。
/// 移植常态两种与“排版进行中”；排版待确认（Web 现在排完直接写进纸里，已不进这一态）与经历资料（未对桌面开放）不移植。
public enum ResumeOrb {
    public enum Action: Equatable, Sendable {
        /// 没有光标所在段时（Web `deepen_all`）：打开段旁对话，先挑一段。
        case deepenAll
        /// 改光标所在的这一段。
        case deepenUnit(String)
        case layout
        /// 正在排版时停下（Web `layout_cancel`）。
        case layoutCancel

        public var label: String {
            switch self {
            case .deepenAll: "挑一段来改"
            case .deepenUnit: "改这一段"
            case .layout: "智能排版"
            case .layoutCancel: "停下"
            }
        }
    }

    public struct Dialogue: Equatable, Sendable {
        public let say: String
        public let note: String?
        public let actions: [Action]
        /// 是否给“或者直接说想改什么…”这一行。
        public var input = true
        /// 第一项是推荐（蓝字）。
        public var accent: Action? { actions.first }
    }

    public static let note = "改好会先写在纸上，你看过再换上。"
    public static let inputPlaceholder = "或者直接说想改什么…"

    public static func dialogue(unitID: String?, unitLabel: String?, layoutBusy: Bool = false) -> Dialogue {
        if layoutBusy { return Dialogue(say: "正在排版，纸面照常能改。", note: nil, actions: [.layoutCancel], input: false) }
        if let unitID, let unitLabel, !unitLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Dialogue(say: "想改「\(compactUnitName(unitLabel))」的话，我先看看这段，再问你几句当时的情况。", note: note,
                            actions: [.deepenUnit(unitID), .layout])
        }
        return Dialogue(say: "想改哪儿？点纸上任意一段，我就去那一段。", note: note, actions: [.deepenAll, .layout])
    }

    /// K3：光标在一段里停够 0.8 秒，小绘左边写“想改「某段」这段？点我改”（Web `HINT_DELAY_MS`）。
    public static let hintDelay: Duration = .milliseconds(800)
    public static func hint(_ unitLabel: String) -> String { "想改「\(compactUnitName(unitLabel))」这段？" }
    public static let hintAction = "点我改"

    /// K3 提示出不出：光标停在能改写的一段、没被点外面收起、白板没开、没在打字 / 选字、小绘没在段旁、没在排版、没在说别的话。
    public static func hintAllowed(cursorUnit: Bool, dismissed: Bool, open: Bool, typing: Bool, away: Bool, disabled: Bool,
                                   layoutBusy: Bool, hasSelection: Bool, saying: Bool) -> Bool {
        cursorUnit && !dismissed && !open && !typing && !away && !disabled && !layoutBusy && !hasSelection && !saying
    }

    /// 选中了一句再点小绘：小绘直接去管这一句（Web `orbTakesSelection`）。
    public static func takesSelection(hasSelection: Bool, lineID: String?, layoutBusy: Bool) -> Bool {
        hasSelection && !(lineID ?? "").isEmpty && !layoutBusy
    }

    /// 白板上“或者直接说想改什么…”点开后的输入框占位（Web `TalkInput placeholder`）。
    public static let inputExpandedPlaceholder = "想改什么，直接说"

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
