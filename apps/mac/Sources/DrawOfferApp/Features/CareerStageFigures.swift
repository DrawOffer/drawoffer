import DrawOfferCore
import SwiftUI

/// 投递详情右侧的状态图形（Figma 07N · 03「左右布局与状态图形」，Web `progress/stageFigure.tsx`）。
/// 每件画在 480×500 的画板上，地面在 y=470；top 是这件东西最高处，外框只占 top 到地面这一段，
/// 放进页面后按各自外轮廓和左边文字共用一条中线。形状画在 Canvas 上，文字和可点的地方是上面一层。
/// 颜色：蓝＝轮到你；橙＝没答好、出错或快到期；没有颜色＝在等，或已经结束。
enum SF {
    static let ink = Color(hex: 0x1D1D1B)
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xD9822B)
    static let edge = Color(hex: 0xE7E5DE)
    static let sub = Color(hex: 0x6C6C65)
    static let mute = Color(hex: 0x96968F)
    static let pale = Color(hex: 0xA9A8A2)

    static let paper = (Color.white, Color(hex: 0xFAF9F5))
    static let fold = (Color.white, Color(hex: 0xF4F2EC))
    static let flap = (Color.white, Color(hex: 0xF7F5F0))
    static let box = (Color(hex: 0xFDFCFA), Color(hex: 0xEFEDE6))
    static let note = (Color(hex: 0xFFFEFA), Color(hex: 0xF6F2E6))
    static let seal = (Color(hex: 0x5581E2), Color(hex: 0x335FC4))
}

// MARK: - 画板

/// 画板上的一笔：形状、填充、描边和投影，对应 SVG 里的一个元素。
struct SFArt {
    enum Lift { case none, lift, under, near, small, soft, cast, contact }
    enum Paint { case color(Color), gradient(Color, Color) }
    let context: GraphicsContext

    func draw(_ path: Path, fill: Paint? = nil, opacity: Double = 1, stroke: Color? = nil, width: CGFloat = 1, dash: [CGFloat] = [], cap: CGLineCap = .butt,
              join: CGLineJoin = .miter, strokePaint: Paint? = nil, lift: Lift = .none) {
        context.drawLayer { layer in
            layer.opacity = opacity
            switch lift {
            case .none: break
            case .lift:
                layer.addFilter(.shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1))
                layer.addFilter(.shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 12))
            case .under: layer.addFilter(.shadow(color: .black.opacity(0.05), radius: 9, x: 0, y: 6))
            case .near: layer.addFilter(.shadow(color: .black.opacity(0.09), radius: 5, x: 0, y: 4))
            case .small: layer.addFilter(.shadow(color: .black.opacity(0.16), radius: 3.5, x: 2, y: 4))
            case .soft: layer.addFilter(.blur(radius: 9))
            case .cast: layer.addFilter(.blur(radius: 4.5))
            case .contact: layer.addFilter(.blur(radius: 2))
            }
            if let fill { layer.fill(path, with: shading(fill, path)) }
            if let paint = strokePaint ?? stroke.map(Paint.color) {
                layer.stroke(path, with: shading(paint, path), style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: join, dash: dash))
            }
        }
    }

    /// SVG 的 objectBoundingBox 渐变，斜向 (0.12, 0.16) → (0.72, 0.96)。
    private func shading(_ paint: Paint, _ path: Path) -> GraphicsContext.Shading {
        switch paint {
        case .color(let color): return .color(color)
        case .gradient(let from, let to):
            let box = path.boundingRect
            return .linearGradient(Gradient(colors: [from, to]), startPoint: CGPoint(x: box.minX + box.width * 0.12, y: box.minY + box.height * 0.16),
                                   endPoint: CGPoint(x: box.minX + box.width * 0.72, y: box.minY + box.height * 0.96))
        }
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }
    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)) }
    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path { Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)) }
    static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Path {
        Path { path in path.move(to: CGPoint(x: x1, y: y1)); path.addLine(to: CGPoint(x: x2, y: y2)) }
    }
    /// translate(x y) rotate(deg)，再可选地先平移 (pre)。
    static func place(_ path: Path, x: CGFloat, y: CGFloat, rotate degrees: CGFloat = 0, pre: CGPoint = .zero) -> Path {
        path.applying(CGAffineTransform(translationX: pre.x, y: pre.y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: x, y: y)))
    }

    /// 稿里的 SVG 路径（M/L/H/V/C/Z 及小写相对写法）。
    static func svg(_ d: String) -> Path {
        var path = Path()
        var tokens: [String] = []
        var number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for char in d {
            if char.isLetter { flush(); tokens.append(String(char)) }
            else if char == "-" { flush(); number = "-" }
            else if char == "." && number.contains(".") { flush(); number = "." }
            else if char == " " || char == "," { flush() }
            else { number.append(char) }
        }
        flush()
        var index = 0, command = "M"
        var point = CGPoint.zero, start = CGPoint.zero
        func next() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index]) ?? 0) }
        while index < tokens.count {
            if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
            let relative = command == command.lowercased()
            let base = relative ? point : .zero
            switch command.uppercased() {
            case "M":
                point = CGPoint(x: base.x + next(), y: base.y + next()); start = point; path.move(to: point)
                command = relative ? "l" : "L"
            case "L": point = CGPoint(x: base.x + next(), y: base.y + next()); path.addLine(to: point)
            case "H": point.x = (relative ? point.x : 0) + next(); path.addLine(to: point)
            case "V": point.y = (relative ? point.y : 0) + next(); path.addLine(to: point)
            case "C":
                let c1 = CGPoint(x: base.x + next(), y: base.y + next()), c2 = CGPoint(x: base.x + next(), y: base.y + next())
                point = CGPoint(x: base.x + next(), y: base.y + next())
                path.addCurve(to: point, control1: c1, control2: c2)
            case "Z": path.closeSubpath(); point = start
            default: index += 1
            }
        }
        return path
    }
}

/// 一件图形：画板 480×500，外框高 470 - top。
struct SFFigure<Overlay: View>: View {
    let top: CGFloat
    let label: String
    let draw: (SFArt) -> Void
    @ViewBuilder var overlay: () -> Overlay

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in draw(SFArt(context: context)) }.frame(width: 480, height: 500).allowsHitTesting(false)
            overlay()
        }
        .frame(width: 480, height: 500, alignment: .topLeading)
        .offset(y: -top)
        .frame(width: 480, height: 470 - top, alignment: .topLeading)
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// `.sf-t`：画板上一处绝对定位的字；行高按 CSS 行盒，字在行盒里竖直居中。
struct SFText: View {
    let text: String
    let x: CGFloat
    let y: CGFloat
    var w: CGFloat? = nil
    var size: CGFloat
    var lineHeight: CGFloat
    var weight: Font.Weight = .regular
    var serif = false
    var color: Color = SF.ink
    var center = false
    var body: some View {
        Text(text).font(serif ? V3.serif(size) : V3.sans(size, weight: weight)).foregroundStyle(color)
            .lineLimit(1).truncationMode(.tail)
            .frame(width: w, height: lineHeight, alignment: center ? .center : .leading)
            .fixedSize(horizontal: w == nil, vertical: true)
            .offset(x: x, y: y)
    }
}

/// `.sf-hit`：图上可点的一块（左边已有同一动作的按钮时只给鼠标用）。
struct SFHit: View {
    let rect: CGRect
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Color.clear.frame(width: rect.width, height: rect.height).contentShape(RoundedRectangle(cornerRadius: 6)) }
            .buttonStyle(.plain).offset(x: rect.minX, y: rect.minY).accessibilityLabel(label)
    }
}

/// `button.sf-row`：题目纸上的一行，悬停变墨色。
struct SFRow: View {
    let text: String
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    var color: Color = SF.sub
    var weight: Font.Weight = .regular
    var action: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        let label = Text(text).font(V3.sans(15, weight: weight)).foregroundStyle(hover ? SF.ink : color).lineLimit(1).truncationMode(.tail)
            .frame(width: w, height: 24, alignment: .leading)
        Group {
            if let action { Button(action: action) { label.contentShape(Rectangle()) }.buttonStyle(.plain).onHover { hover = $0 }.help(text) }
            else { label.help(text) }
        }.offset(x: x, y: y)
    }
}

// MARK: - 公用的形

extension SFArt {
    /// 落在地面上的影子：一层散开偏右，一层贴着底边。
    func ground(_ x: CGFloat, _ w: CGFloat) {
        draw(Self.ellipse(x + w * 0.6 + 20, 469, w * 0.4, 7), fill: .color(.black), opacity: 0.12, lift: .soft)
        draw(Self.ellipse(x + w / 2, 469.5, w / 2 - 3, 2.5), fill: .color(.black), opacity: 0.16, lift: .contact)
    }

    func sheet() {
        ground(86, 308)
        draw(Self.place(Self.rect(0, 0, 308, 404, r: 5), x: 104.5, y: 49.7, rotate: 4), fill: .color(Color(hex: 0xF6F5F0)), stroke: SF.edge, lift: .under)
        draw(Self.rect(86.5, 66.5, 307, 403, r: 5), fill: .gradient(SF.paper.0, SF.paper.1), stroke: SF.edge, lift: .lift)
    }

    func clip(_ color: Color) {
        draw(Self.place(Self.svg("M5 14v26c0 8 12 8 12 0V9C17-3 0-3 0 9v33c0 16 22 16 22 0V14"), x: 116, y: 50), stroke: color, width: 2.6, cap: .round)
    }

    func pencil(x: CGFloat, y: CGFloat, length: CGFloat, color: Color, tilt: CGFloat) {
        let body = length - 24 - 23
        let at = { (path: Path) in Self.place(path, x: x, y: y, rotate: tilt) }
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.09), radius: 5, x: 0, y: 4))
            let art = SFArt(context: layer)
            art.draw(at(Self.rect(1.5, 0.5, 9, 13, r: 3)), fill: .color(Color(hex: 0xEFEDE6)), stroke: Color(hex: 0xDCDAD2))
            art.draw(at(Self.rect(1, 11, 10, 12)), fill: .color(Color(hex: 0xC9C7C0)))
            art.draw(at(Self.rect(0, 23, 12, body)), fill: .color(color))
            art.draw(at(Self.rect(4, 23, 4, body)), fill: .color(.white), opacity: 0.22)
            art.draw(at(Self.svg("M0 \(length - 24)h12l-6 24z")), fill: .color(Color(hex: 0xECD5B1)))
            art.draw(at(Self.svg("M4 \(length - 8)h4l-2 8z")), fill: .color(SF.ink))
        }
    }

    static let rings: [CGFloat] = [70.4, 106.8, 143.2, 179.6, 216, 252.4, 288.8, 325.2, 361.6, 398]

    func calendarPad(ribbon: Bool = false) {
        ground(52, 376)
        draw(Self.rect(55, 156, 370, 314, r: 6), fill: .color(Color(hex: 0xE9E7E0)))
        draw(Self.rect(54, 153.5, 372, 311, r: 6), fill: .color(Color(hex: 0xF3F1EB)), stroke: SF.edge)
        draw(Self.rect(52.5, 150.5, 375, 309, r: 6), fill: .gradient(SF.paper.0, SF.paper.1), stroke: SF.edge, lift: .lift)
        for x in Self.rings {
            draw(Self.rect(x - 1.4, 162, 10, 9, r: 4), fill: .color(Color(hex: 0x2B2B29)))
            draw(Self.rect(x + 1.2, 131.2, 4.8, 35.6, r: 2.4), stroke: SF.ink, width: 2.4)
        }
        if ribbon { draw(Self.svg("M352 150h30v108l-15-12-15 12z"), fill: .color(SF.blue), lift: .small) }
    }

    /// 斜搭在纸上的铅笔：笔尖在 (x, y)，笔尾朝右上。
    func leaningPencil(x: CGFloat, y: CGFloat) {
        draw(Self.place(Self.rect(0, 0, 210, 9, r: 4.5), x: x + 20, y: y - 3, rotate: -44.5), fill: .color(.black), opacity: 0.2, lift: .cast)
        let at = { (d: String) in Self.place(Self.svg(d), x: x, y: y, rotate: -46, pre: CGPoint(x: 0, y: -7)) }
        draw(at("M0 7 34 0v14Z"), fill: .color(Color(hex: 0xECD2A4)))
        draw(at("m0 7 34 2.5V14Z"), fill: .color(Color(hex: 0xDCBD88)))
        draw(at("m0 7 10-2.1v4.2Z"), fill: .color(SF.ink))
        draw(at("M30 2.3C30 .8 31 0 33 0h189v4.6H33c-1.8 0-3-.8-3-2.3Z"), fill: .color(Color(hex: 0x6F97EE)))
        draw(at("M28.5 7c0-1.6 1.5-2.4 3.5-2.4h190v4.8H32c-2 0-3.5-.8-3.5-2.4Z"), fill: .color(SF.blue))
        draw(at("M30 11.7c0-1.5 1.2-2.3 3-2.3h189V14H33c-2 0-3-.8-3-2.3Z"), fill: .color(Color(hex: 0x2D58B8)))
        draw(at("M216 0h4v14h-4Z"), fill: .color(Color(hex: 0xF3F1EA)))
        draw(at("M220 0h11c3.5 0 5 3 5 7s-1.5 7-5 7h-11Z"), fill: .color(SF.ink))
    }

    /// 一枚十八齿的章。
    func seal(_ cx: CGFloat, _ cy: CGFloat) {
        let teeth = Path { path in
            for index in 0..<36 {
                let radius: CGFloat = index % 2 == 1 ? 29.4 : 32
                let angle = CGFloat.pi * CGFloat(index) / 18
                let point = CGPoint(x: cx + radius * sin(angle), y: cy - radius * cos(angle))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        draw(teeth, fill: .gradient(SF.seal.0, SF.seal.1), width: 2, join: .round, strokePaint: .gradient(SF.seal.0, SF.seal.1), lift: .near)
        draw(Self.circle(cx, cy, 20.3), stroke: Color(hex: 0x2D55B0), width: 1.6)
    }

    static let check = "M0 4.8 3.6 8.5 10 0"
    func checkMark(x: CGFloat, y: CGFloat) {
        draw(Self.place(Self.svg(Self.check), x: x, y: y), stroke: SF.ink, width: 1.6, cap: .round, join: .round)
    }

    func wave(y: CGFloat, color: Color, from: Int = 0, x: CGFloat = 118, bars: Int = 77) {
        draw(Self.wavePath(y: y, from: from, x: x, bars: bars), stroke: color, width: 1.5, cap: .round)
    }

    /// 声纹：沿用模拟面试的竖线，只是示意，不是这段录音的真实波形。
    static let waveHeights: [CGFloat] = [3.8, 6.8, 11, 12.8, 13.2, 10.2, 5.8, 10, 16.4, 19.6, 15, 17, 18.4, 12.6, 10.4, 11.6, 6.2, 9.6, 15.4, 10.4, 8.8, 7.6, 10.8, 18.4, 22.2, 18.8, 22.6, 31.4, 27.2, 23.4, 31, 24.7, 24.2, 15, 8, 12.2, 13, 22.2, 13.4, 20.8, 13, 15, 8.4, 10.4, 17.6, 10.8, 18.8, 15, 8.8, 7.6, 12.6, 14.2, 23.4, 25.4, 17, 24.2, 23, 13.4, 15.4, 10, 6.6, 5, 7.6, 10.4, 6.6, 6.2, 5, 4.2, 7.6, 5, 2.8, 1.4, 1.4, 1.6, 1.8, 1.6, 1.4, 1.4, 2.4, 3.8, 4.2, 5.8, 3.4, 4.2, 3, 5, 7.2, 4.6, 6.6, 5.8, 7.2, 10, 8.4, 9.4, 13.2, 12.2, 11, 5.8, 4.4]

    static func wavePath(y: CGFloat, from: Int = 0, x: CGFloat = 118, bars: Int = 77) -> Path {
        Path { path in
            for index in 0..<bars {
                let edge = min(1, CGFloat(index + 1) / 5, CGFloat(bars - index) / 5)
                let height = max(1.4, waveHeights[(from + index) % waveHeights.count] * edge)
                path.move(to: CGPoint(x: x + CGFloat(index) * 3.2, y: y - height / 2))
                path.addLine(to: CGPoint(x: x + CGFloat(index) * 3.2, y: y + height / 2))
            }
        }
    }
}

// MARK: - 01 待投递、02 没记是哪份简历

/// 准备投的那份简历：版式是示意，姓名、板块和经历取自这份简历，底下蓝字是和岗位对得上的技能。
struct ResumeFigure: View {
    let sketch: CareerJourney.ResumeSketch?
    let matched: [String]
    let label: String
    var onOpen: (() -> Void)?

    var body: some View {
        if let sketch {
            SFFigure(top: 54, label: label, draw: { art in
                art.sheet()
                art.clip(SF.blue)
                art.draw(SFArt.circle(340, 140, 24), fill: .color(Color(hex: 0xE7E5DF)))
                art.draw(SFArt.rect(118, 182, 244, 1), fill: .color(Color(hex: 0xECEAE4)))
                art.draw(SFArt.rect(118, 181.5, 26, 2), fill: .color(SF.blue))
            }) {
                SFText(text: sketch.name ?? "简历", x: 118, y: 116, w: 180, size: 25, lineHeight: 36, serif: true)
                if let headline = sketch.headline { SFText(text: headline, x: 118, y: 153, w: 180, size: 11, lineHeight: 15, color: SF.sub) }
                resume(sketch).offset(x: 118, y: 200)
                if let onOpen { SFHit(rect: CGRect(x: 86, y: 66, width: 308, height: 404), label: "打开简历", action: onOpen) }
            }
        } else {
            BlankResumeFigure(clip: SF.blue, label: label, onPick: onOpen)
        }
    }

    private func resume(_ sketch: CareerJourney.ResumeSketch) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(sketch.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title).font(V3.sans(11.5, weight: .medium)).foregroundStyle(SF.ink).lineLimit(1).frame(height: 15)
                    ForEach(Array(section.entries.enumerated()), id: \.offset) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text(entry.period).font(V3.sans(9)).foregroundStyle(SF.mute).fixedSize()
                        }
                        .font(V3.sans(10, weight: .medium)).foregroundStyle(Color(hex: 0x3A3A37)).frame(height: 13).padding(.top, 8)
                        bar(238 - CGFloat(index) * 22).padding(.top, 8)
                        if index == 0 { bar(196).padding(.top, 6.5) }
                    }
                }
            }
            if !matched.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sketch.skillsTitle ?? "专业技能").font(V3.sans(11.5, weight: .medium)).foregroundStyle(SF.ink).frame(height: 15)
                    Text(matched.joined(separator: " · ")).font(V3.sans(10, weight: .medium)).foregroundStyle(SF.blue).lineLimit(1).frame(height: 13)
                }
            }
        }
        .frame(width: 244, height: 252, alignment: .topLeading).clipped()
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.2).fill(Color(hex: 0xE2E0DA)).frame(width: width, height: 4.5)
    }
}

struct BlankResumeFigure: View {
    var clip: Color = SF.pale
    let label: String
    var onPick: (() -> Void)?
    var body: some View {
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(224, 238, 206), (236, 200, 0), (248, 220, 0), (290, 238, 272), (302, 200, 0), (356, 238, 338), (368, 200, 0), (380, 220, 0), (422, 238, 404)]
        SFFigure(top: 54, label: label, draw: { art in
            art.sheet()
            art.clip(clip)
            art.draw(SFArt.rect(118, 122, 92, 13, r: 3), fill: .color(Color(hex: 0xE9E7E1)))
            art.draw(SFArt.rect(118, 148, 60, 7, r: 3), fill: .color(Color(hex: 0xE9E7E1)))
            art.draw(SFArt.circle(340, 140, 24), fill: .color(Color(hex: 0xEFEDE8)))
            for (y, width, head) in bars {
                if head > 0 { art.draw(SFArt.rect(118, head, 48, 7, r: 3), fill: .color(Color(hex: 0xE4E2DC))) }
                art.draw(SFArt.rect(118, y, width, 5, r: 2.5), fill: .color(Color(hex: 0xEFEDE8)))
            }
        }) {
            if let onPick { SFHit(rect: CGRect(x: 86, y: 66, width: 308, height: 404), label: "给这次投递选一份简历", action: onPick) }
        }
    }
}

// MARK: - 03 筛选中：封好的信封，邮戳是投递日期和渠道

struct SentFigure: View {
    let date: String
    let channel: String?
    var body: some View {
        SFFigure(top: 150, label: "\(date) 投出去的简历", draw: { art in
            art.ground(55, 370)
            art.draw(SFArt.rect(55.5, 208.5, 369, 261, r: 6), fill: .color(Color(hex: 0xEFEDE6)), stroke: SF.edge)
            art.draw(SFArt.rect(78.5, 150.5, 323, 199, r: 4), fill: .gradient(SF.paper.0, SF.paper.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.rect(108, 174, 96, 9, r: 3), fill: .color(Color(hex: 0xE2E0DA)))
            art.draw(SFArt.rect(108, 194, 60, 6, r: 3), fill: .color(Color(hex: 0xE2E0DA)))
            art.draw(SFArt.place(SFArt.svg("m0 0 185 140L370 0v256c0 4-2 6-6 6H6c-4 0-6-2-6-6z"), x: 55, y: 208), fill: .gradient(SF.fold.0, SF.fold.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.svg("m55 466 185-138 185 138"), stroke: Color(hex: 0xE4E2DA), width: 1.2, join: .round)
            art.draw(SFArt.rect(368.5, 262.5, 35, 41, r: 2), fill: .color(.white), stroke: Color(hex: 0xDCDAD2))
            art.draw(SFArt.rect(373, 267, 26, 32, r: 1), fill: .color(SF.ink))
            let stamp = { (r: CGFloat) in SFArt.place(SFArt.circle(40, 40, r), x: 288.6, y: 257.2, rotate: -12) }
            art.draw(stamp(37.3), stroke: Color(hex: 0x55554F), width: 1.4)
            art.draw(stamp(31.6), stroke: Color(hex: 0x55554F), width: 0.8)
        }) {
            VStack(spacing: 0) {
                Text(date).font(V3.sans(17, weight: .medium)).frame(height: 22)
                if let channel, channel.count <= 4 { Text(channel).font(V3.sans(10)).frame(height: 13) }
            }
            .foregroundStyle(Color(hex: 0x55554F)).frame(width: 80, height: 80)
            .rotationEffect(.degrees(-12), anchor: .topLeading).offset(x: 288.6, y: 257.2)
        }
    }
}

// MARK: - 04 时间待安排

struct AskDayFigure: View {
    let month: Int
    var onPick: (() -> Void)?
    var body: some View {
        SFFigure(top: 130, label: "还没定时间", draw: { art in
            art.calendarPad()
            art.pencil(x: 398.8, y: 236.9, length: 236, color: SF.blue, tilt: 16)
        }) {
            SFText(text: "\(month) 月", x: 84, y: 195, size: 16, lineHeight: 22, weight: .medium, color: SF.sub)
            SFText(text: "哪一天？", x: 82, y: 226, size: 50, lineHeight: 72, serif: true, color: Color(hex: 0xD2D1CB))
            if let onPick { SFHit(rect: CGRect(x: 52, y: 150, width: 376, height: 310), label: "安排时间", action: onPick).accessibilityHidden(true) }
        }
    }
}

// MARK: - 05 笔试待做、06 笔试做完

struct WrittenDueFigure: View {
    let title: String
    let date: String
    let time: String
    let note: String
    let mine: Bool
    var body: some View {
        let rows: [CGFloat] = [312, 350, 388, 426]
        SFFigure(top: 54, label: title, draw: { art in
            art.sheet()
            // 答题卡：还没考，四行圈都空着
            for y in rows { for x in [162, 200, 238, 276] as [CGFloat] { art.draw(SFArt.circle(x, y, 9.3), stroke: Color(hex: 0xD3D0C6), width: 1.4) } }
            art.leaningPencil(x: 274, y: 314)
        }) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, y in
                SFText(text: "\(index + 1)", x: 120, y: y - 10, size: 14, lineHeight: 20, serif: true, color: SF.mute).accessibilityHidden(true)
            }
            SFText(text: title, x: 120, y: 94, size: 14, lineHeight: 20, color: SF.sub)
            SFText(text: date, x: 116, y: 112, size: 72, lineHeight: 100, serif: true)
            SFText(text: time, x: 120, y: 218, size: 17, lineHeight: 24, weight: .medium)
            SFText(text: note, x: 120, y: 248, size: 14, lineHeight: 20, color: mine ? SF.blue : SF.sub)
        }
    }
}

struct SFPaperItem: Identifiable {
    let id: String
    let title: String
    let mark: CareerJourney.PaperMark
    var open: (() -> Void)? = nil
}

/// 题目纸：标题 + 题数，左边一列小圆点（答到位是对勾、没答好是橙点），右上搭一支铅笔。
private struct PaperHead: View {
    let title: String
    let count: String?
    var far = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(V3.serif(24)).frame(height: 34)
            if let count { Text(count).font(V3.sans(13)).foregroundStyle(far ? SF.sub : SF.mute) }
        }.fixedSize().offset(x: 118, y: 102)
    }
}

extension SFArt {
    func marks(_ items: [SFPaperItem], top: CGFloat = 169, step: CGFloat = 40) {
        for (index, item) in items.prefix(7).enumerated() {
            let y = top + CGFloat(index) * step
            switch item.mark {
            case .good: checkMark(x: 118, y: y - 5)
            case .weak: draw(Self.circle(123, y, 3.6), fill: .color(SF.orange))
            default: draw(Self.circle(123, y, 3), fill: .color(Color(hex: 0xCFCEC9)))
            }
        }
    }
}

struct WrittenListFigure: View {
    let title: String
    let items: [SFPaperItem]
    let onOpen: () -> Void
    let onAdd: () -> Void
    var body: some View {
        SFFigure(top: 54, label: title, draw: { art in
            art.sheet()
            art.marks(items)
            art.pencil(x: 382.7, y: 200.1, length: 236, color: SF.ink, tilt: 14)
        }) {
            PaperHead(title: title, count: items.isEmpty ? nil : "\(items.count) 题")
            if items.isEmpty { SFRow(text: "把题目记下来", x: 118, y: 157, w: 212, color: SF.blue, weight: .medium, action: onAdd) }
            ForEach(Array(items.prefix(7).enumerated()), id: \.element.id) { index, item in
                SFRow(text: item.title, x: 140, y: 157 + CGFloat(index) * 40, w: 190, color: item.mark == .weak ? SF.ink : SF.sub, action: onOpen)
            }
        }
    }
}

// MARK: - 07 面试已约好、17 等结果

/// 台历上地方小，考点只写冒号、括号前的主名，全名在悬停和朗读里。
private func topicName(_ label: String) -> String {
    let name = label.split(whereSeparator: { $0 == "：" || $0 == "（" }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
    return name.count > 1 ? name : label
}

/// topics：长期记忆里没答稳的考点，写在日期右边；没有时只有日期，居中。
struct DayFigure: View {
    let day: Date
    let time: String?
    let ribbon: Bool
    var topics: [(ref: String, label: String)] = []
    var onPractice: ((String, String) -> Void)?
    var body: some View {
        let parts = Beijing.calendar.dateComponents([.month, .day], from: day)
        let beside = !topics.isEmpty
        SFFigure(top: 130, label: "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日", draw: { art in art.calendarPad(ribbon: ribbon) }) {
            text("\(parts.month ?? 0) 月", x: 84, y: 195, size: 16, lineHeight: 22, weight: .medium, color: SF.sub, beside: beside)
            text("\(parts.day ?? 0)", x: 77, y: 196, size: 122, lineHeight: 175, serif: true, beside: beside)
            text([CareerDeckFormat.weekday(day), time].compactMap { $0 }.joined(separator: " "), x: 84, y: 395, size: 17, lineHeight: 23, weight: .medium, beside: beside)
            if beside {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(topics, id: \.ref) { topic in
                        Button { onPractice?(topic.ref, topic.label) } label: {
                            HStack(spacing: 13) {
                                Circle().fill(SF.orange).frame(width: 7, height: 7)
                                Text(topicName(topic.label)).font(V3.sans(15, weight: .medium)).foregroundStyle(SF.ink).lineLimit(1).truncationMode(.tail)
                            }.frame(height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(topic.label).accessibilityLabel(topic.label)
                    }
                }.frame(width: 152, alignment: .leading).offset(x: 262, y: 286)
            }
        }
    }

    @ViewBuilder private func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, lineHeight: CGFloat, weight: Font.Weight = .regular,
                                   serif: Bool = false, color: Color = SF.ink, beside: Bool) -> some View {
        if beside { SFText(text: value, x: x, y: y, size: size, lineHeight: lineHeight, weight: weight, serif: serif, color: color) }
        else { SFText(text: value, x: 52, y: y, w: 376, size: size, lineHeight: lineHeight, weight: weight, serif: serif, color: color, center: true) }
    }
}

struct WaitFigure: View {
    let days: Int
    let label: String
    var body: some View {
        SFFigure(top: 130, label: label, draw: { art in art.calendarPad() }) {
            SFText(text: label, x: 84, y: 195, size: 16, lineHeight: 22, weight: .medium, color: SF.sub)
            if days > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(days)").font(V3.serif(140)).frame(height: 201)
                    Text("天").font(V3.sans(18, weight: .medium))
                }.fixedSize().offset(x: 80, y: 200)
            } else {
                SFText(text: "今天", x: 82, y: 240, size: 72, lineHeight: 104, serif: true)
            }
        }
    }
}

// MARK: - 08 面试当天：钟面走到现在，蓝色一格是开始的时刻

struct ClockFigure: View {
    let now: Date
    let start: Date
    var body: some View {
        let hours = { (date: Date) -> CGFloat in
            let parts = Beijing.calendar.dateComponents([.hour, .minute], from: date)
            return (CGFloat((parts.hour ?? 0) % 12) + CGFloat(parts.minute ?? 0) / 60) * 30
        }
        let minute = CGFloat(Beijing.calendar.component(.minute, from: now)) * 6
        let startAngle = hours(start)
        let angles = [hours(now), minute]
        let low = angles.contains { $0 > 125 && $0 < 235 }
        let high = angles.contains { $0 > 305 || $0 < 55 }
        SFFigure(top: 122, label: "\(CareerDeckFormat.clock(start)) 开始", draw: { art in
            func point(_ angle: CGFloat, _ length: CGFloat) -> CGPoint {
                CGPoint(x: 240 + length * sin(angle * .pi / 180), y: 290 - length * cos(angle * .pi / 180))
            }
            func tick(_ angle: CGFloat, _ inner: CGFloat, _ outer: CGFloat) -> Path {
                let a = point(angle, inner), b = point(angle, outer)
                return SFArt.line(a.x, a.y, b.x, b.y)
            }
            art.ground(90, 300)
            art.draw(SFArt.circle(172, 457, 13), fill: .color(SF.ink))
            art.draw(SFArt.circle(308, 457, 13), fill: .color(SF.ink))
            art.draw(SFArt.circle(240, 290, 165.5), fill: .gradient(SF.paper.0, SF.paper.1), stroke: SF.ink, width: 5, lift: .lift)
            for index in 0..<12 {
                let angle = CGFloat(index) * 30
                let covered = abs((angle - startAngle + 540).truncatingRemainder(dividingBy: 360) - 180) < 9
                guard !covered else { continue }
                art.draw(tick(angle, index % 3 == 0 ? 132 : 138, 152), stroke: SF.ink, width: index % 3 == 0 ? 3 : 2, cap: .round)
            }
            art.draw(tick(startAngle, 132, 152), stroke: SF.blue, width: 5, cap: .round)
            let hand = point(hours(now), 78), long = point(minute, 118)
            art.draw(SFArt.line(240, 290, hand.x, hand.y), stroke: SF.ink, width: 7, cap: .round)
            art.draw(SFArt.line(240, 290, long.x, long.y), stroke: SF.ink, width: 4, cap: .round)
            art.draw(SFArt.circle(240, 290, 8), fill: .color(SF.ink))
        }) {
            // 时刻写在下半圈；指针压着下半圈、上半圈空着时写到上面去
            SFText(text: "\(CareerDeckFormat.clock(start)) 开始", x: 140, y: low && !high ? 198 : 362, w: 200, size: 14, lineHeight: 20, weight: .medium, color: SF.blue, center: true)
        }
    }
}

// MARK: - 09 面完没记录、10 转写中、11 转写失败：录音落在纸上，一行行变成字

struct RecordFigure: View {
    enum Phase { case empty, running, failed }
    let state: Phase
    var over = false
    var onUpload: (() -> Void)?
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch state {
        case .empty: emptyBody
        case .running, .failed: writingBody
        }
    }

    private var emptyBody: some View {
        let pale = over ? Color(hex: 0xB9CBF1) : Color(hex: 0xDEDCD5)
        return SFFigure(top: 54, label: "这场面试的记录", draw: { art in
            art.sheet()
            art.wave(y: 124, color: pale); art.wave(y: 172, color: pale)
            art.wave(y: 364, color: pale, from: 17); art.wave(y: 412, color: pale, from: 43)
            art.draw(SFArt.place(SFArt.svg("M0 0v9c0 2.7 1.3 4 4 4h24c2.7 0 4-1.3 4-4V0"), x: 224, y: 232), stroke: SF.blue, width: 2.2, cap: .round, join: .round)
            art.draw(SFArt.place(SFArt.svg("M8 0v25M8 0 0 8m8-8 8 8"), x: 232, y: 212), stroke: SF.blue, width: 2.2, cap: .round, join: .round)
        }) {
            SFText(text: over ? "松手就放上来" : "把录音放到这张纸上", x: 86, y: 268, w: 308, size: 16, lineHeight: 23, weight: .medium, color: SF.blue, center: true)
            SFText(text: "m4a、mp3、wav、mp4", x: 86, y: 296, w: 308, size: 12, lineHeight: 18, color: SF.mute, center: true)
            if let onUpload { SFHit(rect: CGRect(x: 86, y: 66, width: 308, height: 404), label: "上传录音", action: onUpload).accessibilityHidden(true) }
        }
    }

    private var writingBody: some View {
        let failed = state == .failed
        let word = failed ? Color(hex: 0xB9B8B2) : SF.ink
        let rest = failed ? Color(hex: 0xE4E2DC) : Color(hex: 0xD3D1CA)
        return SFFigure(top: 54, label: failed ? "录音没转成文字" : "正在把录音转成文字", draw: { art in
            art.sheet()
            for (x, y, w) in [(118, 121, 112), (240, 121, 104), (118, 169, 64), (192, 169, 150)] as [(CGFloat, CGFloat, CGFloat)] {
                art.draw(SFArt.rect(x, y, w, 6, r: 3), fill: .color(word))
            }
            if failed {
                art.wave(y: 220, color: SF.orange, bars: 36)
                art.draw(SFArt.circle(247.2, 220, 4), fill: .color(SF.orange))
            } else {
                art.draw(SFArt.rect(118, 217, 86, 6, r: 3), fill: .color(word))
            }
            art.wave(y: 268, color: rest, from: 3); art.wave(y: 316, color: rest, from: 8)
            art.wave(y: 364, color: rest, from: 24); art.wave(y: 412, color: rest, from: 50, bars: 50)
        }) {
            if !failed {
                // 正在写的那一行一明一暗
                SFArt.wavePath(y: 220, x: 218, bars: 45).stroke(SF.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 480, height: 500).opacity(dim ? 0.35 : 1).allowsHitTesting(false)
                    .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
            }
        }
    }
}

// MARK: - 12 有记录没复盘、13 复盘中、14 复盘失败：题目纸和一支铅笔

struct QuestionsFigure: View {
    enum Tone { case blue, ink, orange }
    let title: String
    let count: String
    let items: [SFPaperItem]
    let tone: Tone
    var body: some View {
        SFFigure(top: 54, label: "面试中问到", draw: { art in
            art.sheet()
            art.marks(items)
            art.pencil(x: 382.7, y: tone == .ink ? 200.1 : 240.1, length: 236, color: tone == .blue ? SF.blue : tone == .orange ? SF.orange : SF.ink, tilt: 14)
        }) {
            PaperHead(title: title, count: count)
            ForEach(Array(items.prefix(7).enumerated()), id: \.element.id) { index, item in
                SFRow(text: item.title, x: 140, y: 157 + CGFloat(index) * 40, w: 190,
                      color: item.mark == .waiting ? Color(hex: 0xB9B8B2) : item.mark == .open ? SF.sub : SF.ink, action: item.open)
            }
        }
    }
}

// MARK: - 15 已复盘有没答好的、16 都答到位

struct ReviewFigure: View {
    let reached: Int
    let total: Int
    let weak: [(id: String, title: String, detail: String?)]
    let good: [(id: String, title: String)]
    let onPractice: (String) -> Void
    let onMore: () -> Void
    var body: some View {
        SFFigure(top: 54, label: "复盘结论", draw: { art in
            art.sheet()
            if !weak.isEmpty {
                for index in 0..<min(3, weak.count) { art.draw(SFArt.circle(123, 224 + CGFloat(index) * 76, 4), fill: .color(SF.orange)) }
            } else {
                for index in 0..<min(6, good.count) { art.checkMark(x: 118, y: 212 + CGFloat(index) * 40) }
            }
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(reached)").font(V3.serif(62)).frame(height: 89)
                Text("/ \(total) 题答到位").font(V3.sans(13)).foregroundStyle(SF.sub)
            }.fixedSize().offset(x: 116, y: 92)
            ForEach(Array(weak.prefix(3).enumerated()), id: \.element.id) { index, item in
                WeakRow(title: item.title, detail: item.detail) { onPractice(item.id) }.offset(x: 142, y: 211 + CGFloat(index) * 76)
            }
            if weak.count > 3 {
                CareerJourneyTextButton(title: "还有 \(weak.count - 3) 题", color: SF.mute, action: onMore).offset(x: 142, y: 434)
            }
            if weak.isEmpty {
                ForEach(Array(good.prefix(6).enumerated()), id: \.element.id) { index, item in
                    SFRow(text: item.title, x: 140, y: 205 + CGFloat(index) * 40, w: 226)
                }
            }
        }
    }

    private struct WeakRow: View {
        let title: String
        let detail: String?
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(V3.sans(17, weight: .medium)).foregroundStyle(SF.ink).underline(hover).lineLimit(1).frame(height: 24)
                    if let detail { Text(detail).font(V3.sans(13)).foregroundStyle(SF.mute).lineLimit(1).frame(height: 18) }
                }.frame(width: 224, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { hover = $0 }.help("练这一题")
        }
    }
}

/// 旧版复盘没有逐题判断，只放结论。
struct ReviewTextFigure: View {
    let title: String
    let text: String
    let onOpen: () -> Void
    var body: some View {
        SFFigure(top: 54, label: "复盘结论", draw: { art in art.sheet() }) {
            SFText(text: title, x: 118, y: 102, size: 24, lineHeight: 34, serif: true)
            Button(action: onOpen) {
                Text(text).font(V3.sans(14.5)).foregroundStyle(Color(hex: 0x55554F)).lineHeight(14.5, 26).lineLimit(10)
                    .frame(width: 244, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain).offset(x: 118, y: 156)
        }
    }
}

// MARK: - 18 口头 Offer、19–22 正式 Offer

private func salarySize(_ value: String, _ size: CGFloat) -> CGFloat {
    let width = value.unicodeScalars.reduce(0.0) { $0 + ($1.value <= 0xFF ? 0.56 : 1) }
    return max(22, min(size, floor(236 / max(1, width))))
}

struct OralOfferFigure: View {
    let salary: String?
    let rows: [(label: String, value: String)]
    var body: some View {
        let shown = salary ?? "没说薪资"
        let size = salarySize(shown, 46)
        SFFigure(top: 143, label: "电话里说的", draw: { art in
            art.ground(96, 288)
            art.draw(SFArt.rect(96.5, 158.5, 287, 311, r: 4), fill: .gradient(SF.note.0, SF.note.1), stroke: Color(hex: 0xEBE6D8), lift: .lift)
            art.draw(SFArt.place(SFArt.rect(0, 0, 104, 28), x: 188.8, y: 143.3, rotate: 3), fill: .color(Color(hex: 0xDDDBD3)), opacity: 0.78)
        }) {
            SFText(text: "电话里说的", x: 126, y: 204, size: 14, lineHeight: 20, color: SF.sub)
            SFText(text: shown, x: 124, y: 232, w: 240, size: size, lineHeight: 66, serif: true, color: salary == nil ? SF.pale : SF.ink)
            ForEach(Array(rows.prefix(3).enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    Text(row.label).foregroundStyle(SF.mute).frame(width: 62, alignment: .leading)
                    Text(row.value).foregroundStyle(SF.ink).lineLimit(1).truncationMode(.tail)
                }.font(V3.sans(14)).frame(width: 236, height: 20, alignment: .leading).offset(x: 126, y: 326 + CGFloat(index) * 34)
            }
        }
    }
}

struct OfferBlankFigure: View {
    let onFill: () -> Void
    var body: some View {
        SFFigure(top: 166, label: "这份 Offer", draw: { art in
            art.ground(66, 348)
            art.draw(SFArt.rect(66.5, 232.5, 347, 237, r: 6), fill: .color(Color(hex: 0xEFEDE6)), stroke: SF.edge)
            art.draw(SFArt.rect(92.5, 166.5, 295, 185, r: 4), fill: .gradient(SF.paper.0, SF.paper.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.place(SFArt.svg("m0 0 174 123.8L348 0v232c0 4-2 6-6 6H6c-4 0-6-2-6-6z"), x: 66, y: 232), fill: .gradient(SF.fold.0, SF.fold.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.svg("m66 470 174-119 174 119"), stroke: Color(hex: 0xE4E2DA), width: 1.2, join: .round)
        }) {
            SFText(text: "待填写", x: 120, y: 192, size: 28, lineHeight: 40, serif: true, color: SF.blue)
            SFHit(rect: CGRect(x: 66, y: 166, width: 348, height: 304), label: "填写 Offer", action: onFill).accessibilityHidden(true)
        }
    }
}

struct OfferFigure: View {
    let offer: CareerJourney.OfferText
    var body: some View {
        let salary = offer.salary ?? "还没填薪资"
        SFFigure(top: 56, label: "这份 Offer", draw: { art in
            art.ground(66, 348)
            art.draw(SFArt.rect(66.5, 252.5, 347, 217, r: 6), fill: .color(Color(hex: 0xEFEDE6)), stroke: SF.edge)
            art.draw(SFArt.rect(92.5, 56.5, 295, 315, r: 4), fill: .gradient(SF.paper.0, SF.paper.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.place(SFArt.svg("m0 0 174 113.4L348 0v212c0 4-2 6-6 6H6c-4 0-6-2-6-6z"), x: 66, y: 252), fill: .gradient(SF.fold.0, SF.fold.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.svg("m66 470 174-109 174 109"), stroke: Color(hex: 0xE4E2DA), width: 1.2, join: .round)
            art.seal(240, 366)
        }) {
            SFText(text: offer.job, x: 120, y: 82, w: 244, size: 13, lineHeight: 20, color: SF.sub)
            SFText(text: salary, x: 118, y: 104, w: 246, size: salarySize(salary, 48), lineHeight: 69, serif: true, color: offer.salary == nil ? SF.pale : SF.ink)
            if let detail = offer.detail { SFText(text: detail, x: 120, y: 174, w: 244, size: 14, lineHeight: 20, color: SF.sub) }
            if let due = offer.due { SFText(text: due, x: 120, y: offer.detail != nil ? 202 : 174, size: 14, lineHeight: 20, weight: .medium, color: SF.orange) }
        }
    }
}

struct OfferAcceptedFigure: View {
    let offer: CareerJourney.OfferText
    var body: some View {
        SFFigure(top: 54, label: "这份 Offer", draw: { art in
            art.sheet()
            art.draw(SFArt.svg("M313 396h16v44l-8-8-8 8zM335 396h16v44l-8-8-8 8z"), fill: .color(Color(hex: 0x345FBD)))
            art.seal(332, 386)
        }) {
            SFText(text: "Offer", x: 118, y: 100, size: 38, lineHeight: 55, serif: true)
            SFText(text: offer.job, x: 120, y: 156, w: 244, size: 14, lineHeight: 20, color: SF.sub)
            if let salary = offer.salary { SFText(text: salary, x: 118, y: 202, w: 246, size: salarySize(salary, 48), lineHeight: 69, serif: true) }
            if let detail = offer.detail { SFText(text: detail, x: 120, y: offer.salary != nil ? 272 : 210, w: 244, size: 14, lineHeight: 20, color: SF.sub) }
            if let done = offer.done { SFText(text: done, x: 120, y: 414, size: 13, lineHeight: 20, color: SF.mute) }
        }
    }
}

struct OfferDeclinedFigure: View {
    var body: some View {
        SFFigure(top: 212, label: "已婉拒的 Offer", draw: { art in
            art.ground(60, 360)
            art.draw(SFArt.rect(60.5, 212.5, 359, 257, r: 6), fill: .gradient(SF.fold.0, SF.fold.1), stroke: SF.edge, lift: .lift)
            art.draw(SFArt.svg("m60 464 180-124 180 124"), stroke: Color(hex: 0xE4E2DA), width: 1.2, join: .round)
            art.draw(SFArt.svg("M60 212h360L240 360z"), fill: .gradient(SF.flap.0, SF.flap.1), stroke: SF.edge, join: .round, lift: .near)
            art.draw(SFArt.rect(239, 212, 2, 258), fill: .color(SF.ink))
            art.draw(SFArt.circle(240, 350, 11), fill: .color(SF.ink))
            art.draw(SFArt.circle(240, 350, 4), fill: .color(Color(hex: 0x55554F)))
        }) { EmptyView() }
    }
}

// MARK: - 23 没通过、24 不继续了：记录收进盒子，盖上或虚掩着

struct ArchiveFigure: View {
    let open: Bool
    let label: String
    var body: some View {
        SFFigure(top: open ? 131 : 206, label: label, draw: { art in
            art.ground(64, 352)
            if open {
                art.draw(SFArt.rect(100.5, 206.5, 279, 59, r: 3), fill: .color(Color(hex: 0xF6F5F0)), stroke: SF.edge)
                art.draw(SFArt.rect(112.5, 214.5, 255, 59, r: 3), fill: .color(Color(hex: 0xF6F5F0)), stroke: SF.edge)
                art.draw(SFArt.rect(124.5, 222.5, 231, 59, r: 3), fill: .color(.white), stroke: SF.edge)
            }
            art.draw(SFArt.rect(74.5, 252.5, 331, 217, r: 4), fill: .gradient(SF.box.0, SF.box.1), stroke: Color(hex: 0xDFDDD5), lift: .lift)
            let lid = open ? SFArt.place(SFArt.rect(0, 0, 352, 60, r: 5), x: 62.1, y: 161.5, rotate: -5) : SFArt.rect(64.5, 206.5, 351, 59, r: 5)
            art.draw(lid, fill: .gradient(SF.fold.0, SF.fold.1), stroke: Color(hex: 0xDFDDD5), lift: .near)
            art.draw(SFArt.rect(186, 336, 108, 44, r: 4), fill: .color(SF.ink))
            art.draw(SFArt.rect(192, 342, 96, 32, r: 2), fill: .color(.white))
            art.draw(SFArt.circle(180, 358, 3.4), fill: .color(SF.ink))
            art.draw(SFArt.circle(300, 358, 3.4), fill: .color(SF.ink))
        }) {
            SFText(text: label, x: 192, y: 348, w: 96, size: 13, lineHeight: 20, weight: .medium, color: SF.sub, center: true)
        }
    }
}
