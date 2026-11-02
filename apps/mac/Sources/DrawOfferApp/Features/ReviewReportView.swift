import AppKit
import DrawOfferCore
import SwiftUI

/// 面试复盘的四页（Web `interviews/report/ReviewReport.tsx`，Figma 26）：总览单独一屏，往下翻一次进详情长页——
/// 没答到位的题一题一张卡（左右翻）、能力台阶、下一步路线。只有总览的掌握度图和地平线是设计稿坐标里的图形，按格子等比缩放。
enum RR {
    static let or = Color(hex: 0xD9822B)
    static let amber = Color(hex: 0xD4990D)
    static let blue = Color(hex: 0x3F6FD8)
    static let ink = Color(hex: 0x1D1D1B)
    static let sub = Color(hex: 0x5F5D57)
    static let mute = Color(hex: 0x9B978C)
    static let line = Color(hex: 0xE6E3DC)
    static func tone(_ q: MockReview.Question) -> Color {
        switch q.outcome { case .reached: return blue; case .unrecorded: return MI.gry; case .oneShort: return amber; case .missed: return or }
    }
    static func pad(_ no: Int) -> String { String(format: "%02d", no) }
}

struct NextInterview: Equatable { let label: String; let date: String; let days: Int }

/// `.rr-btn`：34 高的胶囊按钮；`blue` 是蓝底白字。
struct RRButtonStyle: ButtonStyle {
    var blue = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13.5, weight: .medium)).foregroundStyle(blue ? .white : RR.ink)
            .frame(height: 22).padding(.horizontal, 18).padding(.vertical, 6)
            .background(blue ? (configuration.isPressed ? Color(hex: 0x3562C8) : RR.blue) : .white, in: Capsule())
            .overlay(Capsule().stroke(blue ? RR.blue : Color(hex: 0xD9D6CD)))
            .contentShape(Capsule())
    }
}

/// `.rr-link`：13.5 蓝字；`sub` 是灰字。
struct RRLinkStyle: ButtonStyle {
    var sub = false
    var size: CGFloat = 13.5
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(size)).foregroundStyle(sub ? RR.mute : RR.blue).frame(height: 22).contentShape(Rectangle())
    }
}

struct ReviewReportView<Crumb: View, Actions: View, AbilityExtra: View, NextExtra: View>: View {
    let view: MockReview.View
    var next: NextInterview?
    var paused = false
    @ViewBuilder var crumb: () -> Crumb
    @ViewBuilder var actions: () -> Actions
    let open: (String) -> Void
    let practice: ([MockReview.Question]) -> Void
    let action: (MockReview.Action) -> Void
    var toggleDone: ((Int) -> Void)?
    @ViewBuilder var abilityExtra: () -> AbilityExtra
    @ViewBuilder var nextExtra: () -> NextExtra
    var footnote: String?

    @State private var screen = 0
    @State private var card = 0
    @State private var dir = 1
    @State private var picked: String?
    @State private var lock = Date.distantPast
    @State private var top: CGFloat = 0
    @State private var scrolledAt = Date.distantPast
    @State private var target: Int?
    @State private var frame: CGRect = .zero
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let cardW = geometry.size.width, cardH = geometry.size.height
            let page = min(max(0, cardW - 2 * V3Page<EmptyView>.gutter(card: cardW)), V3Page<EmptyView>.maxWidth(card: cardW))
            let screensH = max(0, cardH - 80)
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    crumb()
                    Spacer(minLength: 0)
                    HStack(spacing: 10) { actions() }
                }.frame(width: page, height: 36).padding(.top, 44)
                ZStack(alignment: .top) {
                    OverviewPage(view: view, page: page, cardW: cardW, cardH: cardH, height: screensH, open: open)
                        .frame(width: cardW, height: screensH)
                        .offset(y: CGFloat(-screen) * screensH)
                        .accessibilityHidden(screen != 0).allowsHitTesting(screen == 0)
                    detail(page: page, height: screensH, cardWidth: cardW)
                        .frame(width: cardW, height: screensH)
                        .offset(y: CGFloat(1 - screen) * screensH)
                        .accessibilityHidden(screen != 1).allowsHitTesting(screen == 1)
                }
                .frame(width: cardW, height: screensH).clipped()
                .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .timingCurve(0.65, 0, 0.35, 1, duration: 0.55), value: screen)
            }
            .frame(width: cardW, height: cardH, alignment: .top)
            .onAppear { frame = geometry.frame(in: .global) }
            .onChange(of: geometry.size) { frame = geometry.frame(in: .global) }
        }
        .background(.white)
        .foregroundStyle(RR.ink)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.downArrow, .upArrow, .leftArrow, .rightArrow, .pageUp, .pageDown]) { press in key(press.key) ? .handled : .ignored }
        .onAppear { install() }
        .task { try? await Task.sleep(for: .milliseconds(300)); focused = true }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        .onChange(of: paused) { if !paused { focused = true } }
    }

    // MARK: 翻页

    private func flip(_ index: Int) {
        lock = Date()
        if index <= 0 { screen = 0; return }
        screen = 1
        target = min(3, index)
    }

    private func key(_ key: KeyEquivalent) -> Bool {
        guard !paused else { return false }
        if screen == 1, sectionAt == 0, key == .leftArrow || key == .rightArrow { step(key == .leftArrow ? -1 : 1); return true }
        let down = key == .downArrow || key == .pageDown, up = key == .upArrow || key == .pageUp
        guard down || up else { return false }
        if screen == 0 { if down { flip(1) }; return true }
        if up && top >= -1 { flip(0); return true }
        return false
    }

    private var sectionAt: Int { top >= -10 ? 0 : 1 }

    /// 总览往下滚一次进详情；详情滚到顶后再往上滚一次回总览。
    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !paused, let window = event.window, window == NSApp.keyWindow, let content = window.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard frame.contains(point) else { return event }
            let now = Date()
            if now.timeIntervalSince(lock) < 0.8 { return screen == 0 || top >= -1 ? nil : event }
            let delta = event.scrollingDeltaY
            if screen == 0 {
                if delta < -3 { flip(1); return nil }
                return delta < 0 ? nil : event
            }
            if delta > 3 && top >= -1 && now.timeIntervalSince(scrolledAt) > 0.4 && event.momentumPhase == [] { flip(0); return nil }
            return event
        }
    }

    private var weak: [MockReview.Question] { MockReview.weak(view) }
    private var rest: [MockReview.Question] { view.questions.filter { q in !weak.contains { $0.id == q.id } } }
    private var total: Int { weak.count + (rest.isEmpty ? 0 : 1) }
    private func step(_ delta: Int) { go(card + delta) }
    private func go(_ index: Int) {
        let target = max(0, min(total - 1, index))
        guard target != card else { return }
        dir = target > card ? 1 : -1
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.78)) { card = target }
    }

    // MARK: 详情长页

    private func detail(page: CGFloat, height: CGFloat, cardWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    section(height: height, page: page) { cards(page: page, height: height) }.id(1)
                        .background(GeometryReader { g in Color.clear.preference(key: ReportTop.self, value: g.frame(in: .named("rr")).minY) })
                    Rectangle().fill(Color(hex: 0xE8E5DE)).frame(width: page, height: 1)
                    section(height: height, page: page) { ability(page: page) }.id(2)
                    Rectangle().fill(Color(hex: 0xE8E5DE)).frame(width: page, height: 1)
                    section(height: height, page: page) { nextPage(page: page) }.id(3)
                }
                // 系统设成始终显示滚动条时，滚动条占掉右边一条；正文仍按整张卡的宽度居中（Web 的滚动条浮在内容上）
                .frame(width: cardWidth).offset(x: Self.legacyScroller / 2)
            }
            .coordinateSpace(name: "rr")
            // 正文按整张卡的宽度居中：系统设成始终显示滚动条时，滚动条不把正文挤偏（Web 的滚动条浮在内容上）
            .scrollIndicators(.automatic)
            .onPreferenceChange(ReportTop.self) { value in top = value; scrolledAt = Date() }
            .onChange(of: target) {
                guard let target else { return }
                let animated = screen == 1 && Date().timeIntervalSince(lock) > 0.05
                if animated { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(target, anchor: .top) } } else { proxy.scrollTo(target, anchor: .top) }
                self.target = nil
            }
        }
    }

    private static var legacyScroller: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    private func section<Content: View>(height: CGFloat, page: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(width: page, alignment: .leading)
            .padding(.top, 16).padding(.bottom, 32)
            .frame(minHeight: height, alignment: .top)
    }

    private func pageTop(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(V3.sans(32, weight: .bold)).frame(height: 44)
            Text(verbatim: sub).font(V3.sans(15.5)).foregroundStyle(RR.mute).frame(height: 24)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 第 2 页：没答到位的题

    @ViewBuilder private func cards(page: CGFloat, height: CGFloat) -> some View {
        let weak = self.weak, rest = self.rest, total = self.total
        let deckH = min(700, max(520, height - 48 - 72 - 36 - 44))
        pageTop(weak.isEmpty ? "这场每道题都答到位了" : "\(weak.count) 道题没答到位",
                weak.isEmpty ? "下面是这场的全部题目，点一格进那道题。" : "先看没答上的，再看差一点的；左右翻，一张一道。")
        .frame(width: page)
        if total > 0 {
            let deckW = min(760, page - 144)
            ZStack {
                if card < total - 2 { back(0xFAF4EA, deckW, deckH).opacity(0.8).rotationEffect(.degrees(3.2), anchor: .bottom).offset(x: 34, y: -10) }
                if card < total - 1 { back(0xFDF8F0, deckW, deckH).rotationEffect(.degrees(1.6), anchor: .bottom).offset(x: 18, y: -6) }
                Group {
                    if let current = weak[safe: card] { QuestionCard(question: current, bubbleMax: (deckW - 80) * 0.8, open: open, practice: practice) }
                    else { RestCard(questions: rest, open: open, next: { flip(2) }) }
                }
                .frame(width: deckW, height: deckH)
                .background(.white).clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.08), radius: 24, y: 18).shadow(color: .black.opacity(0.05), radius: 3, y: 2)
                .id(card)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: CGFloat(70 * dir))), removal: .opacity))
                .zIndex(2)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(weak[safe: card].map { "\(RR.pad($0.no)) \($0.title)" } ?? "其余 \(rest.count) 道")
                HStack {
                    arrow("‹", label: "上一张", disabled: card == 0) { go(card - 1) }
                    Spacer()
                    arrow("›", label: "下一张", disabled: card >= total - 1) { go(card + 1) }
                }.frame(width: deckW + 144).zIndex(3)
            }
            .frame(width: page, height: deckH).padding(.top, 36)
        }
        if total > 1 {
            HStack(spacing: 8) {
                ForEach(Array(weak.enumerated()), id: \.element.id) { index, item in
                    tab(RR.pad(item.no), on: index == card, color: item.outcome == .missed ? RR.or : RR.amber, bold: true) { go(index) }
                }
                if !rest.isEmpty { tab("其余 \(rest.count) 道", on: card == weak.count, color: RR.mute, bold: false, onColor: RR.ink) { go(weak.count) } }
            }.frame(width: page).padding(.top, 20)
        }
    }

    private func back(_ color: UInt32, _ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 22).fill(Color(hex: color)).frame(width: w, height: h)
            .shadow(color: .black.opacity(0.08), radius: 24, y: 18).accessibilityHidden(true)
    }

    private func arrow(_ glyph: String, label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(V3.sans(22)).foregroundStyle(disabled ? Color(hex: 0xCFCABD) : RR.ink)
                .frame(width: 44, height: 44).background(.white, in: Circle())
                .shadow(color: .black.opacity(disabled ? 0.04 : 0.08), radius: disabled ? 4 : 7, y: disabled ? 2 : 4)
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(label)
    }

    private func tab(_ text: String, on: Bool, color: Color, bold: Bool, onColor: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: text).font(V3.sans(12.5, weight: bold ? .medium : .regular)).foregroundStyle(on ? .white : color)
                .frame(height: 24).padding(.horizontal, 10).background(on ? (onColor ?? color) : .clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 第 3 页：能力表现

    @ViewBuilder private func ability(page: CGFloat) -> some View {
        let rows = Array(view.dimensions.prefix(6))
        let assessed = rows.filter { $0.assessed && $0.steps != nil }
        let weakest = assessed.sorted { ($0.steps ?? 0, $0.score ?? 0) < ($1.steps ?? 0, $1.score ?? 0) }.first
        let selected = rows.first { $0.key == picked } ?? weakest ?? rows.first
        let none = !rows.isEmpty && assessed.isEmpty
        let title = weakest.map { ($0.steps ?? 5) <= 3 ? "\($0.label)最值得补一补" : "能力表现" } ?? "能力表现"
        let sub = none ? "这场 \(rows.count) 项能力都没评出来。" : "\(rows.count) 项能力按每道题考到的要点打分，满分 100，按 5 格画。"
        VStack(alignment: .leading, spacing: 0) {
            pageTop(title, sub)
            if none {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Set(rows.map { $0.offReason ?? "" })).sorted(), id: \.self) { reason in
                        (Text(rows.filter { ($0.offReason ?? "") == reason }.map(\.label).joined(separator: "、")).foregroundColor(RR.ink).fontWeight(.semibold)
                         + Text(reason.isEmpty ? "" : "：\(reason)")).font(V3.sans(15)).foregroundStyle(RR.sub)
                    }
                    Text("对不上原话的分数不可靠，所以宁可不评，不代表答得不好；补全面试记录里的回答后可以重新复盘。").font(V3.sans(13.5)).foregroundStyle(RR.mute).padding(.top, 8)
                }.frame(maxWidth: 640, alignment: .leading).padding(.top, 32)
            } else if !rows.isEmpty {
                AbilityChart(rows: rows, selected: selected?.key, page: page) { picked = $0 }.padding(.top, 16)
            }
            HStack(alignment: .top, spacing: 48) {
                if !none, let selected { explain(selected).frame(maxWidth: 720, alignment: .leading) }
                if rows.isEmpty { Text("这场没有能力项的评分").font(V3.sans(14)).foregroundStyle(RR.mute).padding(.top, 32) }
                Spacer(minLength: 0)
                abilityExtra().frame(width: 295, alignment: .leading)
            }.padding(.top, 20).padding(.bottom, 24)
            Spacer(minLength: 0)
            HStack { Spacer(); Button("往下看下一步 ↓") { flip(3) }.buttonStyle(RRButtonStyle(blue: true)) }
        }.frame(width: page, alignment: .leading)
    }

    private func explain(_ item: MockReview.Dimension) -> some View {
        let weak = (item.steps ?? 5) <= 2
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: item.label).font(V3.sans(24, weight: .bold))
                if let score = item.score {
                    (Text("\(score)").font(.system(size: 26, weight: .semibold)).foregroundColor(weak ? RR.or : RR.blue) + Text(" / \(item.max)").font(V3.sans(14)).foregroundColor(RR.mute))
                }
            }.frame(height: 26)
            Text(verbatim: item.assessed ? item.comment ?? "有依据" : item.offReason ?? "").font(V3.sans(16)).lineHeight(16, 28).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
            if let no = item.evidenceNo {
                Button("看第 \(no) 题 ›") { if let q = view.questions.first(where: { $0.no == no }) { open(q.id) } }.buttonStyle(RRLinkStyle())
            }
        }
    }

    // MARK: 第 4 页：下一步

    @ViewBuilder private func nextPage(page: CGFloat) -> some View {
        let items = Array(view.actions.prefix(3))
        let title = items.isEmpty ? "这场没有特别要准备的事" : next.map { "\($0.label)前，建议准备这 \(items.count) 件事" } ?? "下一场之前，建议准备这 \(items.count) 件事"
        VStack(alignment: .leading, spacing: 0) {
            pageTop(title, "根据这场的回答给的建议，按重要程度排，可以挑着做；点题号回到那道题。")
            if !items.isEmpty { NextRoute(items: items, next: next, open: openNo, action: action, toggleDone: toggleDone).frame(width: page).padding(.top, 48) }
            nextExtra().padding(.top, 48)
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                Button("复盘看完了 · 回到第 1 页 ↑") { flip(0) }.buttonStyle(RRLinkStyle(sub: true, size: 12.5))
                if let footnote { Text(verbatim: footnote).font(V3.sans(12.5)).foregroundStyle(RR.mute).frame(height: 22) }
            }.padding(.top, 32)
        }.frame(width: page, alignment: .leading)
    }

    private func openNo(_ no: Int) { if let q = view.questions.first(where: { $0.no == no }) { open(q.id) } }
}

private struct ReportTop: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
