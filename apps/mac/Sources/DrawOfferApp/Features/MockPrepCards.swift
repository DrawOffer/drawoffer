import Foundation
import DrawOfferCore
import SwiftUI

/// 准备题目中间的卡片（Figma 09 · 04 选题动效 04.01–04.04；Web `v2/PrepCards.tsx`）：中间那叠是「本场题目」，两侧各两张候选考点。
/// 读简历：两张资料卡轮流被一道扫描线扫过，扫完一张就抽出一张小卡飞进中间；没有岗位时右边是「方向常考点」。
/// 选题：候选从两侧发上桌；每轮挑一张抬起、上方给理由，再滑进中间那叠，同侧外面的卡向里补位、桌边递补一张；
/// 挑完后两侧留下的都是这场不考的点，淡着停在桌上。生成第一问：那叠最上面一张写「第一题」并轻轻浮着。
struct MockPrepCards: View {
    let prep: JSONValue?
    let frozen: Bool
    let hasJob: Bool

    private static let cx: CGFloat = 684, cy: CGFloat = 444
    private static let pileW: CGFloat = 204, pileH: CGFloat = 136, cardW: CGFloat = 156, cardH: CGFloat = 104
    private static let slotX: [CGFloat] = [-372, -204, 204, 372], slotRot: [Double] = [4, 2, -2, -4], slotDY: [CGFloat] = [10, 2, 2, 10]
    private static let under: [(CGFloat, CGFloat, Double)] = [(6, 8, 3), (-5, 6, -2.5), (3, 3, 1.5)]
    private static let land: [(CGFloat, CGFloat, Double)] = [(2, -3, -1.5), (-2, -6, 1.2), (1, -4, -0.8), (-1, -5, 1.6)]
    static let tags: [String: (label: String, tone: Color)] = [
        "retest": ("复测", MockPalette.orange), "probe": ("补问", MockPalette.blue), "focus": ("你选的", MockPalette.blue),
        "practice": ("练习", MockPalette.mute), "job": ("岗位要求", MockPalette.mute), "basics": ("常考", MockPalette.mute),
        "resume": ("你的经历", MockPalette.mute), "competency": ("综合素质", MockPalette.mute),
    ]

    private enum Phase { case deal, scan, pick, reason, land }
    @State private var landed = 0
    @State private var phase: Phase = .deal
    @State private var firstSeen: String?

    struct Pick: Equatable { var topic: String; var tag: String; var note: String }
    struct Card: Equatable { var key: String; var name: String; var pick: Int?; var slot: Int }
    struct Round { var cards: [Card]; var chosen: String; var pick: Int }

    private var picks: [Pick] { (prep?["picks"]?.items ?? []).map { Pick(topic: $0.text("topic"), tag: $0.text("tag"), note: $0.text("note")) } }
    private var candidates: [String] { (prep?["candidates"]?.items ?? []).compactMap { $0.stringValue } }

    var body: some View {
        let still = frozen || firstSeen == "opening"
        let deck = Self.schedule(picks: picks, candidates: candidates)
        let playing = prep != nil && !still && landed < deck.rounds.count
        ZStack(alignment: .topLeading) {
            if prep == nil {
                pileEmpty(waiting: !still)
                docs(reading: !still)
            } else {
                let round = playing ? deck.rounds[landed] : nil
                let shown = playing ? landed : picks.count
                let opening = prep?.text("stage") == "opening"
                let order = deck.rounds.map(\.pick)
                let last = shown > 0 ? picks[safe: order[safe: shown - 1] ?? shown - 1] : nil
                pile(count: shown, top: opening && !playing ? (prep?.text("first").nonEmptyValue ?? picks.first?.topic ?? "", "第一题", MockPalette.ink) : last.map { ($0.topic, Self.tags[$0.tag]?.label ?? "", Self.tags[$0.tag]?.tone ?? MockPalette.mute) },
                     lifted: opening && !playing)
                ForEach(round?.cards ?? deck.final, id: \.key) { card in table(card, round: round) }
                if let round, let pick = picks[safe: round.pick], let tag = Self.tags[pick.tag] {
                    let slot = round.cards.first { $0.key == round.chosen }?.slot ?? 0
                    Text(verbatim: pick.note.isEmpty ? tag.label : "\(tag.label) · \(pick.note)").font(V3.sans(13, weight: .medium)).foregroundStyle(tag.tone).lineLimit(1).fixedSize()
                        .position(x: Self.cx + Self.slotX[slot], y: Self.cy + Self.slotDY[slot] - 18 - 52 - 12 - 10)
                        .opacity(phase == .reason ? 1 : 0)
                }
            }
            Text("本场题目").font(V3.sans(13)).foregroundStyle(MockPalette.mute).frame(width: 1120, height: 20).offset(x: 124, y: 538)
        }
        .frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
        .accessibilityHidden(true)
        .onAppear { if firstSeen == nil, let prep { firstSeen = prep.text("stage") } }
        .onChange(of: prep?.text("stage")) { _, stage in if firstSeen == nil { firstSeen = stage } }
        .task(id: "\(playing)-\(landed)") {
            guard playing else { return }
            let extra = landed == 0 ? 0.6 : 0
            for (at, next) in [(0.38, Phase.scan), (0.70, .pick), (0.85, .reason), (1.75, .land)] {
                try? await Task.sleep(for: .seconds(at + extra - (next == .scan ? 0 : 0)))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.45)) { phase = next }
            }
            try? await Task.sleep(for: .seconds(0.45))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.45)) { phase = .deal; landed += 1 }
        }
    }

    private func table(_ card: Card, round: Round?) -> some View {
        let chosen = round != nil && card.key == round?.chosen
        let lifted = chosen && (phase == .pick || phase == .reason)
        let moving = chosen && phase == .land
        let landAt = Self.land[(landed) % Self.land.count]
        let x: CGFloat = moving ? landAt.0 : Self.slotX[card.slot]
        let y: CGFloat = moving ? landAt.1 : lifted ? Self.slotDY[card.slot] - 18 : Self.slotDY[card.slot]
        let rot = moving ? landAt.2 : lifted ? 0 : Self.slotRot[card.slot]
        let dim = round == nil ? true : !chosen && phase != .deal && phase != .scan
        let tag = chosen ? round.flatMap { picks[safe: $0.pick] }.flatMap { Self.tags[$0.tag] } : nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MockPalette.edge))
                .shadow(color: .black.opacity(lifted || moving ? 0.1 : 0.05), radius: lifted || moving ? 13 : 7, y: lifted || moving ? 10 : 4)
            Text(verbatim: card.name).font(V3.sans(15, weight: .medium)).foregroundStyle(MockPalette.ink).multilineTextAlignment(.center).lineLimit(2)
                .padding(.horizontal, 12).frame(width: Self.cardW, height: Self.cardH).opacity(dim ? 0.35 : 1)
            if let tag { Text(verbatim: tag.label).font(V3.sans(10, weight: .medium)).foregroundStyle(tag.tone).offset(x: 12, y: 9).opacity(moving ? 1 : 0) }
        }
        .frame(width: Self.cardW, height: Self.cardH)
        .scaleEffect(moving ? Self.pileW / Self.cardW : 1)
        .rotationEffect(.degrees(rot))
        .position(x: Self.cx + x, y: Self.cy + y)
        .zIndex(lifted || moving ? 3 : 1)
        .transition(.opacity.combined(with: .offset(x: card.slot < 2 ? -140 : 140)))
    }

    private func pileEmpty(waiting: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            RoundedRectangle(cornerRadius: 16).strokeBorder(waiting && t < 0.3 ? MockPalette.blue.opacity(0.5) : MockPalette.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: Self.pileW, height: Self.pileH)
        }
        .position(x: Self.cx, y: Self.cy)
    }

    @ViewBuilder private func pile(count: Int, top: (String, String, Color)?, lifted: Bool) -> some View {
        if count == 0 || top == nil {
            pileEmpty(waiting: false)
        } else if let top {
            ForEach(0..<min(count - 1, Self.under.count), id: \.self) { index in
                let item = Self.under[index]
                pileCard.rotationEffect(.degrees(item.2)).position(x: Self.cx + item.0, y: Self.cy + item.1).zIndex(2)
            }
            let at = lifted ? (CGFloat(0), CGFloat(-10), 0.0) : Self.land[(count - 1) % Self.land.count]
            TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
                let float = lifted ? sin(timeline.date.timeIntervalSinceReferenceDate / 3.2 * 2 * .pi) * 4 : 0
                ZStack(alignment: .topLeading) {
                    pileCard
                    Text(verbatim: top.0).font(V3.sans(19, weight: .medium)).foregroundStyle(MockPalette.ink).multilineTextAlignment(.center).lineLimit(2)
                        .padding(.horizontal, 18).frame(width: Self.pileW, height: Self.pileH)
                    Text(verbatim: top.1).font(V3.sans(12, weight: .medium)).foregroundStyle(top.2).offset(x: 16, y: 13)
                }
                .frame(width: Self.pileW, height: Self.pileH)
                .rotationEffect(.degrees(at.2)).position(x: Self.cx + at.0, y: Self.cy + at.1 + float)
            }
            .zIndex(2)
        }
    }

    private var pileCard: some View {
        RoundedRectangle(cornerRadius: 16).fill(.white).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MockPalette.edge))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 6).frame(width: Self.pileW, height: Self.pileH)
    }

    /// 读简历：两张资料卡轮流被扫描线扫过，扫完一张抽出一张小卡飞进中间。
    private func docs(reading: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                doc(hasJob ? "岗位要求" : "方向常考点", x: 290, rot: -3, time: t, lag: 1, reading: reading)
                doc("你的简历", x: -290, rot: 3, time: t, lag: 0, reading: reading)
                if reading {
                    ghost(from: -290, time: t, lag: 0)
                    ghost(from: 290, time: t, lag: 1)
                }
            }
            .frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
        }
    }

    private func doc(_ title: String, x: CGFloat, rot: Double, time: Double, lag: Double, reading: Bool) -> some View {
        let p = reading ? ((time - lag * 1.2).truncatingRemainder(dividingBy: 2.4) + 2.4).truncatingRemainder(dividingBy: 2.4) / 2.4 : 1
        let focused = reading && p < 0.4
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Color(hex: 0xC4D2F0) : MockPalette.edge))
                .shadow(color: focused ? MockPalette.blue.opacity(0.12) : .black.opacity(0.05), radius: focused ? 11 : 7, y: focused ? 8 : 4)
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: title).font(V3.sans(12)).foregroundStyle(MockPalette.mute).frame(height: 18).padding(.bottom, 2)
                ForEach([0.86, 0.62, 0.74], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xEDEDEA)).frame(width: 172 * width, height: 8)
                }
            }.padding(.horizontal, 18).padding(.top, 16)
            if reading && p < 0.4 {
                LinearGradient(colors: [MockPalette.blue.opacity(0), MockPalette.blue.opacity(0.75), MockPalette.blue.opacity(0.75), MockPalette.blue.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 208, height: 2).offset(y: 136 * p / 0.4)
            }
        }
        .frame(width: 208, height: 136).clipShape(RoundedRectangle(cornerRadius: 14))
        .rotationEffect(.degrees(rot)).position(x: Self.cx + x, y: Self.cy)
    }

    private func ghost(from x: CGFloat, time: Double, lag: Double) -> some View {
        let p = ((time - lag * 1.2 - 0.96).truncatingRemainder(dividingBy: 2.4) + 2.4).truncatingRemainder(dividingBy: 2.4) / 2.4
        let travel = min(1, p / 0.35)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(.white).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MockPalette.edge))
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xEDEDEA)).frame(width: 50, height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xEDEDEA)).frame(width: 34, height: 6)
            }.padding(10)
        }
        .frame(width: 70, height: 46)
        .opacity(p < 0.35 ? sin(travel * .pi) : 0)
        .position(x: Self.cx + x * (1 - travel), y: Self.cy - 20 * sin(travel * .pi))
    }

    /// 先排好每一轮开始时桌上的卡和挑哪张（与 Web `schedule` 相同）：挑的那张尽量和上一轮不在同一侧、先挑里侧的；
    /// 挑走后同侧外面的卡向里补位，空出的外侧由桌边递补一张。挑的先后只影响动画，题目顺序仍按 picks。
    static func schedule(picks: [Pick], candidates: [String]) -> (rounds: [Round], final: [Card]) {
        var dealt = 0, serial = 0, cursor = 0
        func nextCandidate(_ table: [Card]) -> String? {
            let on = Set(table.map(\.name))
            for k in 0..<max(candidates.count, 0) {
                let name = candidates[(cursor + k) % candidates.count]
                if !on.contains(name) && !picks.contains(where: { $0.topic == name }) { cursor = (cursor + k + 1) % candidates.count; return name }
            }
            return nil
        }
        func deal(_ table: inout [Card], _ slot: Int, candidate: Bool = false) {
            if !candidate && dealt < picks.count && table.filter({ $0.pick != nil }).count < 3 {
                table.append(Card(key: "p\(dealt)", name: picks[dealt].topic, pick: dealt, slot: slot)); dealt += 1; return
            }
            if let name = nextCandidate(table) { table.append(Card(key: "c\(serial)", name: name, pick: nil, slot: slot)); serial += 1 }
            else if dealt < picks.count { table.append(Card(key: "p\(dealt)", name: picks[dealt].topic, pick: dealt, slot: slot)); dealt += 1 }
        }
        var table: [Card] = []
        for slot in [2, 1, 3, 0] { deal(&table, slot, candidate: slot == 0 && picks.count > 1) }
        var rounds: [Round] = []
        var lastSide = 0
        let sideOf = { (slot: Int) in slot < 2 ? 0 : 1 }
        for _ in 0..<picks.count {
            let on = table.filter { $0.pick != nil }
            guard !on.isEmpty else { break }
            let rank = { (card: Card) in (sideOf(card.slot) != lastSide ? 0 : 2) + ([1, 2].contains(card.slot) ? 0 : 1) }
            guard let chosen = on.sorted(by: { rank($0) < rank($1) }).first, let index = chosen.pick else { break }
            rounds.append(Round(cards: table, chosen: chosen.key, pick: index))
            lastSide = sideOf(chosen.slot)
            var next = table.filter { $0.key != chosen.key }
            let inner = [1, 2][lastSide], outer = [0, 3][lastSide]
            if !next.contains(where: { $0.slot == inner }), let moving = next.firstIndex(where: { $0.slot == outer }) { next[moving].slot = inner }
            for slot in [outer, inner] where !next.contains(where: { $0.slot == slot }) { deal(&next, slot) }
            table = next
        }
        if table.count < 4 {
            let spread = [[], [2], [1, 2], [1, 2, 3]][table.count]
            table = table.sorted { $0.slot < $1.slot }.enumerated().map { index, card in var card = card; card.slot = spread[index]; return card }
        }
        return (rounds, table)
    }
}
