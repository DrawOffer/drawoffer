import Foundation
import DrawOfferCore
import AppKit
import SwiftUI

/// 面试中全屏画面的共用部件（Figma 09 · 03 开始前 / 05 面试中 / 06 文字面试 / 07 结束；Web `v2/SessionChrome.tsx`）：
/// 顶行、大字题目、底部一行（这场要练的、这段回答）。面试中只露当前这一题和当前说话的一方，画面固定 1368 × 828，整体等比缩放。
enum MockFull {
    static let width: CGFloat = 1368
    static let height: CGFloat = 828
    /// Figma 09 的窗口稿 1392 × 852：正文坐标 = 稿内坐标 - 12，顶行（和红绿灯同一行）用负偏移。
    static let windowWidth: CGFloat = 1392
    static let windowHeight: CGFloat = 852
    static let inset: CGFloat = 12
}

/// 场次画面的外框：没有侧栏，白底铺满，按 1392 × 852 的窗口稿等比缩放；正文留 12 的边。
struct MockSessionFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        // 等比缩放后贴顶（水平居中）：顶行要和红绿灯同一行，窗口比稿高时多出来的白在底下，不能居中把顶行压下去
        GeometryReader { geometry in
            let scale = min(geometry.size.width / MockFull.windowWidth, geometry.size.height / MockFull.windowHeight, 1) // 只缩不放，放大会把字拉糊
            ZStack(alignment: .topLeading) { content() }
                .frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
                .offset(x: MockFull.inset, y: MockFull.inset)
                .frame(width: MockFull.windowWidth, height: MockFull.windowHeight, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: (geometry.size.width - MockFull.windowWidth * scale) / 2)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(.white)
    }
}

/// 白底、1px #E4E4E0 描边的系统 Bordered 按钮（Figma `macOS / Button / Bordered`）：32 高，12 号中等字，胶囊圆角。
struct MockBorderedPillStyle: ButtonStyle {
    var padding: CGFloat = 26
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(V3.sans(12, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(MockPalette.ink)
            .padding(.horizontal, padding).frame(height: 32)
            .background { Capsule().fill(configuration.isPressed ? MockPalette.chip : .white).overlay(Capsule().strokeBorder(MockPalette.cl)) }
            .opacity(enabled ? 1 : 0.4).contentShape(Capsule())
    }
}

enum MockSessionText {
    static func who(_ detail: JSONValue) -> String {
        [detail.text("company_name").nonEmptyValue, detail.text("stage_label").nonEmptyValue].compactMap { $0 }.joined(separator: " · ").nonEmptyValue ?? detail.text("resume_title")
    }

    private static let source = ["resume": "来自你的简历", "job": "来自岗位要求", "material": "来自你的资料"]

    static func isIntro(_ detail: JSONValue, _ question: JSONValue) -> Bool { question.text("anchor_kind") == "intro" || MockMap.isIntro(detail, question) }

    /// 大字题目上面那一行（`questionEyebrow`）。
    static func eyebrow(_ detail: JSONValue, _ question: JSONValue?) -> String {
        guard let question else { return "" }
        if MockMap.isIntro(detail, question) { return "开场 · 自我介绍" }
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let round = MockSession.roundOf(detail, question)
        let index = round.flatMap { r in rounds.firstIndex { $0.main.display("id") == r.main.display("id") } } ?? rounds.count - 1
        if question.text("kind") == "follow_up" {
            let at = round?.turns.firstIndex { $0.display("id") == question.display("id") } ?? 1
            return "第 \(index + 1) 题 · 追问 \(at)"
        }
        return ["第 \(index + 1) 题", "共 \(detail["question_count"]?.integer ?? 0) 题", source[question.text("anchor_kind")]].compactMap { $0 }.joined(separator: " · ")
    }

    /// 思考界面的眉题：哪一题，加这一题的结果，不再说题目来源。
    static func thinkingEyebrow(_ detail: JSONValue, _ question: JSONValue?, skipped: Bool) -> String {
        let done = skipped ? "已跳过" : "你答完了"
        let asked = eyebrow(detail, question)
        if let question, question.text("kind") == "main", source[question.text("anchor_kind")] != nil, !MockMap.isIntro(detail, question) {
            return asked.components(separatedBy: " · ").prefix(2).joined(separator: " · ") + " · " + done
        }
        return asked.isEmpty ? done : "\(asked) · \(done)"
    }

    /// 把回答切成普通段和被面试官记下的原话段；找不到的原话跳过，重叠的只留先出现的。
    static func quoteSegments(_ text: String, _ quotes: [String]) -> [(text: String, marked: Bool)] {
        let ranges = quotes.compactMap { quote -> Range<String.Index>? in quote.isEmpty ? nil : text.range(of: quote) }.sorted { $0.lowerBound < $1.lowerBound }
        var segments: [(String, Bool)] = []
        var at = text.startIndex
        for range in ranges where range.lowerBound >= at {
            if range.lowerBound > at { segments.append((String(text[at..<range.lowerBound]), false)) }
            segments.append((String(text[range]), true))
            at = range.upperBound
        }
        if at < text.endIndex { segments.append((String(text[at...]), false)) }
        return segments
    }

    static func elapsed(_ detail: JSONValue, now: Date = Date()) -> String {
        guard let started = CareerApplication.date(detail.text("started_at")) else { return "00:00" }
        return MockSession.mmss(now.timeIntervalSince(started))
    }
}

/// `.mi3-center`：1120 宽、居中排的一行（左边 124）。
struct MockCenterLine: View {
    let text: String
    let top: CGFloat
    var size: CGFloat = 13
    var line: CGFloat = 20
    var color: Color = MockPalette.fnt
    var serif = false
    var body: some View {
        Text(verbatim: text).font(serif ? V3.serif(size) : V3.sans(size)).foregroundStyle(color).lineHeight(size, line, serif ? .serif : .sans)
            .multilineTextAlignment(.center).frame(width: 1120).offset(x: 124, y: top)
    }
}

/// 顶行（`SessionHead`，Figma 09 · 05：和红绿灯同一行，左边从 x 92 起）：没开始或已结束的页面左边是返回；面试进行中左边是这场是谁，中间计时，右边跳过 / 放弃 / 结束。
struct MockSessionHead<Right: View>: View {
    let detail: JSONValue
    var timer: String? = nil
    var back: (label: String, disabled: Bool, action: () -> Void)? = nil
    @ViewBuilder var right: () -> Right
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let back {
                MockBackCrumb(label: back.label, current: MockSessionText.who(detail), disabled: back.disabled, action: back.action).frame(maxWidth: 480, alignment: .leading).offset(x: 80, y: 4)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: MockSessionText.who(detail)).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1)
                    Text(verbatim: detail.text("job_title").nonEmptyValue ?? detail.text("target_role")).font(V3.sans(13)).foregroundStyle(MockPalette.fnt).lineLimit(1)
                }
                .frame(maxWidth: 480, alignment: .leading).frame(height: 20).offset(x: 80, y: 3)
            }
            if let timer {
                Text(verbatim: timer).font(V3.serif(22)).monospacedDigit().foregroundStyle(MockPalette.ink).frame(width: MockFull.width, height: 30).offset(y: 1.5)
                    .accessibilityLabel("用时 \(timer)")
            }
            HStack(spacing: 24) { right() }.frame(height: 32).frame(width: MockFull.width - 96, alignment: .trailing).offset(x: 48, y: -2)
        }
    }
}

extension MockSessionHead where Right == EmptyView {
    init(detail: JSONValue, timer: String? = nil, back: (label: String, disabled: Bool, action: () -> Void)? = nil) {
        self.init(detail: detail, timer: timer, back: back, right: { EmptyView() })
    }
}

/// `.mi3-question`：题目固定在两行大字的位置（左 124、顶 203、1120 × 160），长了收小字号；还没「打」出来的字浅灰。
struct MockBigQuestion: View {
    let text: String
    var shown = Int.max
    var body: some View {
        let count = text.count
        let (size, line): (CGFloat, CGFloat) = count <= 48 ? (46, 64) : count <= 93 ? (36, 50) : count <= 160 ? (28, 40) : (22, 32)
        let typed = String(text.prefix(shown)), rest = shown < count ? String(text.dropFirst(shown)) : ""
        (Text(verbatim: typed).foregroundColor(MockPalette.ink) + Text(verbatim: rest).foregroundColor(MockPalette.faint))
            .font(V3.serif(size)).lineHeight(size, line, .serif).multilineTextAlignment(.center)
            .frame(width: 1120, height: 160, alignment: .top).clipped().offset(x: 124, y: 203)
            .accessibilityLabel(text)
    }
}

/// 底部一行（`SessionFoot`）：顶上一根细线，左边「这场要练的 …」或一句提示，右边操作。
struct MockSessionFoot<Left: View, Right: View>: View {
    var goal: String? = nil
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(MockPalette.line).frame(height: 1)
            HStack(spacing: 12) {
                if Left.self != EmptyView.self { left() } else if let goal = goal?.nonEmptyValue {
                    Text("这场要练的").foregroundStyle(MockPalette.fnt)
                    Text(verbatim: goal).fontWeight(.medium).foregroundStyle(MockPalette.ink)
                }
            }
            .font(V3.sans(13)).lineLimit(1).frame(height: 20).offset(y: 25)
            HStack(spacing: 20) { right() }.frame(height: 38).frame(maxWidth: .infinity, alignment: .trailing).offset(y: 16)
        }
        .frame(width: MockFull.width - 96, height: 76, alignment: .topLeading).offset(x: 48, y: 740)
    }
}

extension MockSessionFoot where Left == EmptyView {
    init(goal: String?, @ViewBuilder right: @escaping () -> Right) { self.init(goal: goal, left: { EmptyView() }, right: right) }
}

/// 这段回答（`AnswerFeedback`）：语速、长停顿、口头禅、面试官记下几处；都没有时不显示。
struct MockAnswerFeedback: View {
    let feedback: JSONValue?
    let notes: Int
    var body: some View {
        let voice = feedback.flatMap { $0 == .null ? nil : $0 }
        if voice != nil || notes > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text("这段回答").foregroundStyle(MockPalette.fnt)
                if let voice {
                    let pace = voice.text("pace")
                    item(voice["chars_per_minute"]?.integer ?? 0, "字/分", ["slow": "语速偏慢", "ok": "语速合适", "fast": "语速偏快"][pace] ?? "", tone: pace == "ok" ? nil : MockPalette.orange)
                    item(voice["long_pauses"]?.integer ?? 0, "次", "长停顿")
                    if let filler = voice.text("filler").nonEmptyValue, (voice["filler_count"]?.integer ?? 0) > 0 {
                        item(voice["filler_count"]?.integer ?? 0, "次", "“\(filler)”偏多", tone: MockPalette.orange)
                    }
                }
                if notes > 0 { item(notes, "处", "面试官记下", tone: MockPalette.blue) }
            }
            .font(V3.sans(13)).lineLimit(1)
        }
    }
    private func item(_ value: Int, _ unit: String, _ label: String, tone: Color? = nil) -> some View {
        (Text(verbatim: "\(value)").font(V3.serif(20)).foregroundColor(tone ?? MockPalette.ink) + Text(verbatim: " \(unit)  \(label)").foregroundColor(tone ?? MockPalette.fnt))
    }
}

/// `FinishStats`：结束确认里的三个数（题、次追问、用时），数字和单位排在一行，三列各 132 宽（Figma 09 · 05.06）。
struct MockFinishStats: View {
    let detail: JSONValue
    let elapsed: String
    var body: some View {
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let answered = rounds.filter { $0.main.text("answer_status") != "pending" }.count
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        HStack(spacing: 0) {
            stat("\(answered) / \(detail["question_count"]?.integer ?? 0)", "题"); stat("\(follows)", "次追问"); stat(elapsed, "用时")
        }
    }
    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: value).font(V3.serif(24)).foregroundStyle(MockPalette.ink)
            Text(verbatim: label).font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
        }
        .lineLimit(1).frame(width: 132, height: 34, alignment: .leading)
    }
}

/// 面试中的确认卡（Figma 09 · 05.06，460 宽 Sheet）：标题 17、说明 14，右下「取消」是 32 高的白底描边按钮，确认是 38 高的墨黑胶囊。
struct MockSessionConfirm<Extra: View>: View {
    let title: String
    let desc: String
    let confirm: String
    var cancel = "取消"
    var busy = false
    var busyLabel: String? = nil
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var extra: () -> Extra
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(V3.sans(17, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: 24, alignment: .leading)
            Text(verbatim: desc).font(V3.sans(14)).foregroundStyle(MockPalette.sub).lineHeight(14, 22)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            extra().padding(.top, 23)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(cancel, action: onCancel).buttonStyle(MockBorderedPillStyle(padding: 23)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? busyLabel ?? confirm : confirm, action: onConfirm).buttonStyle(MockPillStyle(height: 38, padding: 24)).disabled(busy)
            }.padding(.top, 30)
        }
        .padding(.horizontal, 33).padding(.top, 30).padding(.bottom, 23)
        .frame(width: 460, alignment: .leading)
    }
}

extension MockSessionConfirm where Extra == EmptyView {
    init(title: String, desc: String, confirm: String, cancel: String = "取消", busy: Bool = false, busyLabel: String? = nil, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.init(title: title, desc: desc, confirm: confirm, cancel: cancel, busy: busy, busyLabel: busyLabel, onConfirm: onConfirm, onCancel: onCancel, extra: { EmptyView() })
    }
}

/// 思考中的三个点：依次闪一下蓝。
struct MockThinkDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (t - Double(index) * 0.2).truncatingRemainder(dividingBy: 1.2) / 1.2
                    Circle().fill(phase > 0.1 && phase < 0.3 ? MockPalette.blue : MockPalette.faint).frame(width: 8, height: 8)
                }
            }
        }
        .frame(width: MockFull.width).offset(y: 366).accessibilityHidden(true)
    }
}

/// 场次画面里的确认（Web mi3 `ConfirmDialog`）：放进窗口正中的 Sheet。
extension View {
    func mockDialog<C: View>(_ dialog: Binding<String?>, _ name: String, @ViewBuilder content: @escaping () -> C) -> some View {
        centeredSheet(isPresented: Binding(get: { dialog.wrappedValue == name }, set: { if !$0 { dialog.wrappedValue = nil } }), content: content)
    }
}

/// Alert 里竖排整宽的按钮：主操作墨黑（危险操作红色），次操作 6% 黑底。（`CenteredModal` 共用）
struct AlertButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, secondary }
    var kind: Kind
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = kind == .primary ? MI.ink : kind == .danger ? V3.red : .black.opacity(0.06)
        return configuration.label.font(V3.sans(13, weight: .medium)).foregroundStyle(kind == .secondary ? MI.ink : .white)
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(fill.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.5).contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 应用图标（花标）：Alert 用它，与系统 NSAlert 一致。（`CenteredModal`、首页记忆共用）
struct AppIconImage: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(MI.ink)
        }
    }
}
