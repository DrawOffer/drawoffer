import DrawOfferCore
import SwiftUI

/// Web `features/interviews/progress/progressDeck.css` 的颜色。
enum PD {
    static let ink = Color(hex: 0x1D1D1B)
    static let body = Color(hex: 0x55554F)
    static let mute = Color(hex: 0x96968F)
    static let blue = Color(hex: 0x3F6FD8)
    static let blueText = Color(hex: 0x145ED6)
    static let tint = Color(hex: 0xE9F1FD)
    static let red = Color(hex: 0xC2412D)
    static let redTint = Color(hex: 0xFDEEEA)
    static let act = Color(hex: 0xC9D6EE)
    static let done = Color(hex: 0x96ACD6)
    static let dash = Color(hex: 0xC4C4BE)
    static let edge = Color(hex: 0xECEBE6)
    static let field = Color(hex: 0xDED7CC)
    static let axis: CGFloat = 68
}

/// `.pd-btn`：36 高胶囊；一页只有一个黑色实心主按钮，没通过是红字。
struct PDButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, reject }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        // Web `.pd-page button { font: inherit }` 盖过按钮类的字号：页面里的按钮都是 14px 常规
        configuration.label.font(V3.sans(14)).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 36)
            .foregroundStyle(kind == .primary ? .white : kind == .reject ? PD.red : PD.ink)
            .background(kind == .primary ? PD.ink : .white, in: Capsule())
            .overlay(Capsule().stroke(kind == .primary ? PD.ink : kind == .reject ? Color(hex: 0xEFD2CC) : V3.cl))
            .opacity(!enabled ? 0.55 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// `.pd-mini-btn`：缩略图虚线框里的小按钮。
struct PDMiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14)).foregroundStyle(PD.ink)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(configuration.isPressed ? V3.field : .white, in: Capsule())
            .overlay(Capsule().stroke(V3.cl))
    }
}

/// 左栏站点线（`.pd-rail`）：日期 | 节点 | 内容三列，点哪一站右边就换成哪一站。
struct CareerStationRail: View {
    let deck: CareerDeck
    let application: JSONValue
    let picked: Int
    let now: Date
    let pick: (String) -> Void
    let next: (Bool) -> Void

    var body: some View {
        let line = deck.line(now: now)
        let ended = deck.ended
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(line.stations.enumerated()), id: \.element.station.id) { index, entry in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entry.rows.enumerated()), id: \.offset) { position, row in
                        rowView(row, station: entry.station, index: index, first: index == 0 && position == 0)
                    }
                }
            }
            if let label = line.next {
                let toApply = deck.pending && deck.ended == nil
                let offer = deck.stations.last?.kind == .offer
                Button { if !offer { next(toApply) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(V3.sans(15, weight: .medium)).frame(height: 22)
                        if !offer { Text(toApply ? "点这里记录投递" : "有结果后点这里添加").font(V3.sans(13)).frame(height: 18) }
                    }
                    .foregroundStyle(PD.mute)
                    .padding(.leading, PD.axis + 24).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        ZStack {
                            Path { path in path.move(to: CGPoint(x: PD.axis, y: -14)); path.addLine(to: CGPoint(x: PD.axis, y: 10)) }
                                .stroke(PD.dash, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            Circle().stroke(Color(hex: 0xBDBDB7), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).background(Circle().fill(.white))
                                .frame(width: 12, height: 12).position(x: PD.axis, y: 11)
                        }.frame(width: PD.axis * 2, height: 22, alignment: .topLeading)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.top, 14).disabled(offer)
                    .accessibilityLabel(label + (offer ? "" : toApply ? " 点这里记录投递" : " 有结果后点这里添加"))
            }
            let endedText = ended.map { ["rejected": "没通过", "accepted": "接受了 Offer", "withdrew": "我不继续了"][$0.kind.rawValue] ?? "已结束" }
            Text(ended.map { "\(endedText ?? "") · \(CareerDeckFormat.monthDay($0.at)) · 共 \(deck.days) 天" } ?? "共 \(deck.days) 天 · \(deck.stations.count) 站")
                .font(.system(size: 12)).foregroundStyle(ended?.kind == .rejected ? PD.red : PD.mute)
                .padding(.leading, PD.axis + 24).padding(.top, 16)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("投递进度")
    }

    /// 每一行在节点列自己画那一段线：实线已走过，灰虚线往后。
    private func lineSegment(_ tone: CareerLineTone, top: CGFloat = 0, height: CGFloat? = nil) -> some View {
        GeometryReader { geometry in
            if tone != .none {
                Path { path in
                    path.move(to: CGPoint(x: PD.axis, y: top))
                    path.addLine(to: CGPoint(x: PD.axis, y: height.map { top + $0 } ?? geometry.size.height))
                }
                .stroke(tone == .next ? PD.dash : PD.act, style: tone == .next ? StrokeStyle(lineWidth: 1, dash: [3, 3]) : StrokeStyle(lineWidth: 2))
            }
        }
    }

    @ViewBuilder private func rowView(_ row: CareerLineRow, station: CareerStation, index: Int, first: Bool) -> some View {
        switch row {
        case .stop(let state, let tone):
            stop(station, state: state, tone: tone, index: index, first: first)
        case .span(let days, let tone):
            Color.clear.frame(height: 40).frame(maxWidth: .infinity)
                .background(lineSegment(tone))
                .overlay(alignment: .topLeading) {
                    if days > 0 {
                        Text("\(days) 天").font(.system(size: 11, weight: .medium)).foregroundStyle(PD.mute)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(.white, in: Capsule()).overlay(Capsule().stroke(PD.edge))
                            .fixedSize().position(x: PD.axis, y: 20)
                    }
                }
                .accessibilityHidden(true)
        case .event(let text, let detail, let upcoming, let tone):
            HStack(spacing: 8) {
                Text(text).font(V3.sans(13, weight: .medium)).foregroundStyle(upcoming ? PD.blueText : PD.ink).fixedSize()
                if let detail { Text(detail).font(V3.sans(12.5)).foregroundStyle(PD.mute).lineLimit(1) }
            }
            .padding(.leading, PD.axis + 24).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(lineSegment(tone))
            .overlay(alignment: .leading) {
                Circle().stroke(PD.blue, lineWidth: 1.5).background(Circle().fill(.white)).frame(width: 8, height: 8).offset(x: PD.axis - 4)
            }
        case .wait(let label, let tone):
            Text(label).font(V3.sans(12, weight: .medium)).foregroundStyle(PD.blueText)
                .padding(.horizontal, 10).frame(height: 22).background(PD.tint, in: Capsule())
                .padding(.leading, PD.axis + 24).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(lineSegment(tone))
        case .today(let date, let tone):
            HStack(spacing: 0) {
                Text("今天").font(V3.sans(13, weight: .medium)).frame(width: PD.axis - 22, alignment: .trailing)
                Spacer().frame(width: 46)
                Text(date).font(.system(size: 13)).foregroundStyle(PD.body)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(lineSegment(tone))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(PD.ink).frame(width: 20, height: 2).offset(x: PD.axis - 10) }
        }
    }

    private func stop(_ station: CareerStation, state: CareerLineRow.Stop, tone: CareerLineTone, index: Int, first: Bool) -> some View {
        let isPicked = index == picked
        let current = state == .current
        let failed = state == .failed
        let detail = stopDetail(station, current: current)
        let color: Color = failed ? PD.red : current ? PD.blueText : PD.ink
        let name = deck.pending && deck.ended == nil && station.kind == .apply ? "待投递" : station.short
        return Button { pick(station.id) } label: {
            HStack(alignment: .top, spacing: 0) {
                Text(CareerDeckFormat.monthDay(station.start)).font(.system(size: 13, weight: current ? .semibold : .medium))
                    .foregroundStyle(failed ? PD.red : current ? PD.blueText : PD.body)
                    .frame(width: PD.axis - 22, alignment: .trailing).padding(.top, 13)
                Spacer().frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(V3.sans(16, weight: isPicked ? .semibold : .medium)).foregroundStyle(color).lineLimit(1).frame(height: 22)
                    if let detail { Text(detail).font(V3.sans(13)).foregroundStyle(failed ? PD.red : PD.mute).lineLimit(1).frame(height: 18) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StopHover())
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            // 首站从圆点开始画；已结束的最后一站只补上一段到圆点
            lineSegment(tone == .none && !first ? .done : tone, top: first ? 26 : 0, height: tone == .none ? (first ? 0 : 26) : nil)
        )
        .overlay(alignment: .topLeading) { dot(state, picked: isPicked).position(x: PD.axis, y: 26) }
        .accessibilityLabel("查看" + station.short)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder private func dot(_ state: CareerLineRow.Stop, picked: Bool) -> some View {
        switch state {
        case .current where !picked:
            Circle().fill(.white).frame(width: 18, height: 18).overlay(Circle().stroke(PD.blue, lineWidth: 2)).overlay(Circle().fill(PD.blue).frame(width: 7, height: 7))
        case .offer:
            Circle().fill(PD.blue).frame(width: 18, height: 18).overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
        default:
            let failed = state == .failed
            Circle().fill(picked ? (failed ? PD.red : PD.blue) : failed ? PD.red : PD.done)
                .frame(width: picked ? 16 : 12, height: picked ? 16 : 12)
                .overlay(Image(systemName: failed ? "xmark" : "checkmark").font(.system(size: picked ? 8 : 6.5, weight: .bold)).foregroundStyle(.white))
                .background(Circle().fill(failed ? PD.redTint : PD.tint).frame(width: 26, height: 26).opacity(picked ? 1 : 0))
        }
    }

    private func stopDetail(_ station: CareerStation, current: Bool) -> String? {
        if current && (station.kind == .written || station.kind == .interview) { return "\(CareerDeckFormat.monthDay(station.start)) 收到通知" }
        if current && station.kind == .screening { return nil }
        let text = CareerDeckCopy.edgeDetail(station, application: application)
        return text.isEmpty ? nil : text
    }
}

private struct StopHover: View {
    @State private var hover = false
    var body: some View {
        RoundedRectangle(cornerRadius: 12).fill(hover ? Color(hex: 0xF6F6F3) : .clear).onHover { hover = $0 }
    }
}

enum CareerDeckCopy {
    static func mode(_ session: JSONValue, short: Bool = false) -> String {
        switch session.text("mode") {
        case "video": return short ? "视频" : "视频面试"
        case "onsite": return short ? "现场" : "现场面试"
        case "phone": return "电话"
        default: return "其他方式"
        }
    }

    static func edgeDetail(_ station: CareerStation, application: JSONValue) -> String {
        switch station.kind {
        case .apply: return [CareerDeck.source(application), application.text("resume_title_snapshot").nonEmptyValue].compactMap { $0 }.joined(separator: " · ")
        case .oc: return [application.text("oc_salary_text").nonEmptyValue, "口头意向"].compactMap { $0 }.joined(separator: " · ")
        case .offer: return "正式 Offer"
        default: break
        }
        guard let session = station.session else {
            return station.end.map { "\(CareerDeckFormat.dayCount(station.start, $0)) 天出结果" } ?? ""
        }
        let start = CareerApplication.date(session.text("start_at")) ?? station.start
        let end = CareerApplication.date(session.text("end_at")) ?? start
        if station.kind == .written {
            if session.text("schedule_kind") == "open_window", let s = CareerApplication.date(session.text("answer_plan_start_at")), let e = CareerApplication.date(session.text("answer_plan_end_at")) {
                return "\(CareerDeckFormat.monthDay(s)) \(CareerDeckFormat.clock(s)) – \(CareerDeckFormat.clock(e)) 完成"
            }
            return "\(CareerDeckFormat.monthDay(start)) \(CareerDeckFormat.clock(start)) – \(CareerDeckFormat.clock(end)) 完成"
        }
        return "\(CareerDeckFormat.monthDay(start)) \(CareerDeckFormat.clock(start)) – \(CareerDeckFormat.clock(end)) · \(mode(session))"
    }
}

/// 叠起来的日历页（`.pd-cal`）：蓝色页头写月份，中间日期，下面星期。
struct CareerCalendarPage: View {
    let date: Date
    var tone: String?
    var body: some View {
        let head = tone == "red" ? PD.red : tone == "gray" ? PD.mute : PD.blue
        let shape = RoundedRectangle(cornerRadius: 24)
        ZStack {
            shape.fill(.white).overlay(shape.stroke(Color(hex: 0xE5EAF3))).shadow(color: Color(hex: 0x1A3373).opacity(0.05), radius: 5, y: 3)
                .rotationEffect(.degrees(-7)).offset(x: -6, y: 6)
            shape.fill(.white).overlay(shape.stroke(Color(hex: 0xE5EAF3))).shadow(color: Color(hex: 0x1A3373).opacity(0.05), radius: 5, y: 3)
                .rotationEffect(.degrees(5)).offset(x: 6, y: 4)
            VStack(spacing: 0) {
                Text("\(Beijing.calendar.component(.month, from: date)) 月").font(V3.sans(18, weight: .medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 42).background(head)
                    .overlay(alignment: .top) {
                        HStack {
                            RoundedRectangle(cornerRadius: 3).frame(width: 6, height: 14)
                            Spacer()
                            RoundedRectangle(cornerRadius: 3).frame(width: 6, height: 14)
                        }.foregroundStyle(tone == nil ? Color(hex: 0xD6E2F8) : PD.edge).padding(.horizontal, 34).offset(y: -3)
                    }
                Text("\(Beijing.calendar.component(.day, from: date))").font(.system(size: 54, weight: .semibold)).kerning(-1.6).frame(height: 60).padding(.top, 10)
                Text(CareerDeckFormat.weekday(date)).font(V3.sans(17)).foregroundStyle(PD.mute).frame(height: 22).padding(.top, 4)
                Spacer(minLength: 0)
            }
            .background(.white).clipShape(shape).overlay(shape.stroke(Color(hex: 0xE5EAF3)))
            .shadow(color: Color(hex: 0x1A3373).opacity(0.10), radius: 10, y: 8)
        }
        .frame(width: 144, height: 156).padding(.top, 8).padding(.leading, 6)
        .accessibilityHidden(true)
    }
}

/// 缩略图（`.pd-thumb`）：预览纸片、名字、说明行。
struct CareerThumb: Identifiable {
    enum Preview {
        case info([(String, String?)])
        case doc(String, [CGFloat])
        case list(kicker: String?, items: [String])
        case text(kicker: String?, text: String, strong: Bool)
        case files([String], more: Int)
        case qa([String])
        case checks([(String, Bool, () -> Void)])
        case written([(String, String, String)])
        case empty(icon: String, text: String, actions: [(String, () -> Void)])
    }
    let id: String
    let name: String
    var meta: String?
    let preview: Preview
    var open: (() -> Void)?
    var isEmpty: Bool { if case .empty = preview { return true }; return false }
}

struct CareerThumbShelf: View {
    let title: String
    let items: [CareerThumb]
    let all: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(V3.sans(13)).foregroundStyle(PD.mute).frame(height: 18)
                Spacer()
                Button("全部资料 ›", action: all).buttonStyle(.plain).font(V3.sans(14)).foregroundStyle(PD.body)
            }.frame(height: 22).padding(.bottom, 14)
            HStack(alignment: .top, spacing: 20) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        sheet(item)
                        Group {
                            if let open = item.open, !item.isEmpty { Button(item.name, action: open).buttonStyle(.plain).font(V3.sans(14)) } else { Text(item.name).font(V3.sans(14, weight: .medium)) }
                        }.foregroundStyle(PD.ink).lineLimit(1).frame(height: 20).padding(.top, 14)
                        Text(item.meta ?? " ").font(V3.sans(13)).foregroundStyle(PD.mute).lineLimit(1).frame(height: 18).padding(.top, 2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, 64)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    private func sheet(_ item: CareerThumb) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return preview(item.preview)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: item.isEmpty ? .center : .topLeading)
            .background(item.isEmpty ? Color(hex: 0xFAFAF8) : .white, in: shape)
            .overlay(shape.stroke(item.isEmpty ? Color(hex: 0xD6D6D0) : PD.edge, style: StrokeStyle(lineWidth: 1, dash: item.isEmpty ? [4, 3] : [])))
            .shadow(color: .black.opacity(item.isEmpty ? 0 : 0.06), radius: 9, y: 6)
            .contentShape(shape)
            .onTapGesture { if !item.isEmpty { item.open?() } }
    }

    private func bars(_ widths: [CGFloat]) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                    Capsule().fill(Color(hex: 0xEEEEEA)).frame(width: geometry.size.width * width / 100, height: 6)
                }
            }
        }.frame(height: CGFloat(widths.count) * 15)
    }

    @ViewBuilder private func preview(_ preview: CareerThumb.Preview) -> some View {
        switch preview {
        case .info(let rows):
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text(row.0).foregroundStyle(PD.mute).fixedSize()
                        Spacer(minLength: 0)
                        Text(row.1 ?? "没填").fontWeight(row.1 == nil ? .regular : .medium).foregroundStyle(row.1 == nil ? PD.mute : PD.ink).lineLimit(1)
                    }
                    .font(V3.sans(12.5)).frame(height: 18).padding(.vertical, 7)
                    .overlay(alignment: .bottom) { if index < rows.count - 1 { Rectangle().fill(Color(hex: 0xF1F0EC)).frame(height: 1) } }
                }
            }
        case .doc(let title, let widths):
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(V3.sans(13, weight: .medium)).lineLimit(1)
                bars(widths)
            }
        case .list(let kicker, let items):
            VStack(alignment: .leading, spacing: 0) {
                if let kicker { Text(kicker).font(V3.sans(11.5, weight: .medium)).foregroundStyle(PD.mute).frame(height: 16).padding(.bottom, 4) }
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) { Circle().fill(Color(hex: 0xB9B9B2)).frame(width: 4, height: 4); Text(item).lineLimit(1) }
                        .font(V3.sans(12.5)).foregroundStyle(PD.body).frame(height: 25)
                }
            }
        case .text(let kicker, let text, let strong):
            VStack(alignment: .leading, spacing: 0) {
                if let kicker { Text(kicker).font(V3.sans(11.5, weight: .medium)).foregroundStyle(PD.mute).frame(height: 16).padding(.bottom, 4) }
                Text(text).font(V3.sans(12.5, weight: strong ? .medium : .regular)).foregroundStyle(strong ? PD.ink : PD.body).lineLimit(2).lineSpacing(4)
                if strong { bars([82, 60, 70]).padding(.top, 8) }
            }
        case .files(let names, let more):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 10) {
                        Text(CareerFileBadge.badge(name)).font(.system(size: 9, weight: .semibold)).foregroundStyle(PD.mute).frame(width: 30, height: 34).background(V3.field, in: RoundedRectangle(cornerRadius: 6))
                        Text(name).font(V3.sans(12.5)).foregroundStyle(PD.body).lineLimit(1)
                    }.frame(height: 46)
                }
                if more > 0 { Text("还有 \(more) 份").font(V3.sans(12)).foregroundStyle(PD.mute) }
            }
        case .qa(let questions):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(questions.prefix(2).enumerated()), id: \.offset) { index, question in
                    HStack(spacing: 10) { Text("问").font(V3.sans(11, weight: .medium)).foregroundStyle(index == 0 ? PD.ink : PD.mute).frame(width: 14, alignment: .leading); Text(question).font(V3.sans(12.5)).foregroundStyle(PD.body).lineLimit(1) }.frame(height: 25)
                    HStack(spacing: 10) {
                        Text("答").font(V3.sans(11, weight: .medium)).foregroundStyle(PD.mute).frame(width: 14, alignment: .leading)
                        GeometryReader { geometry in Capsule().fill(Color(hex: 0xEEEEEA)).frame(width: geometry.size.width * (index == 0 ? 0.78 : 0.56), height: 6).frame(maxHeight: .infinity) }
                    }.frame(height: 25)
                }
            }
        case .checks(let items):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        Button(action: item.2) {
                            RoundedRectangle(cornerRadius: 4).stroke(item.1 ? PD.blue : Color(hex: 0xC9C9C3), lineWidth: 1.4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(item.1 ? PD.blue : .white))
                                .overlay { if item.1 { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) } }
                                .frame(width: 15, height: 15).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(item.0).accessibilityAddTraits(item.1 ? .isSelected : [])
                        Text(item.0).font(V3.sans(12.5)).foregroundStyle(item.1 ? PD.mute : PD.body).strikethrough(item.1).lineLimit(1)
                    }.frame(height: 30)
                }
            }
        case .written(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0).font(.system(size: 12, weight: .medium)).foregroundStyle(PD.mute).frame(width: 14)
                        Text(row.1).font(V3.sans(12.5)).foregroundStyle(PD.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.2 == "correct" ? "✓" : row.2 == "wrong" ? "✕" : "").font(V3.sans(12.5)).foregroundStyle(row.2 == "wrong" ? PD.red : PD.ink).frame(width: 14)
                    }.frame(height: 30)
                }
            }
        case .empty(let icon, let text, let actions):
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color(hex: 0xA3A39C)).frame(width: 18, height: 18)
                Text(text).font(V3.sans(12.5)).foregroundStyle(PD.body).multilineTextAlignment(.center).frame(minHeight: 18)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in Button(action.0, action: action.1).buttonStyle(PDMiniButtonStyle()) }
                    }.padding(.top, 4)
                }
            }.frame(maxWidth: .infinity)
        }
    }
}
