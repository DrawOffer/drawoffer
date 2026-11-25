import SwiftUI

/// Figma 第 17 页（macOS 外壳）侧栏的线性图标，路径照抄设计稿导出的 SVG（描边 1.6、圆头圆角）。
/// `box` 是设计稿里图标的画板边长，绘制时按实际 frame 等比缩放。
enum SideIcon {
    case home, doc, layout, kanban, cal, mic, brief, folder, side, bell, pen, updown, down

    var box: CGFloat {
        switch self {
        case .side: 16
        case .bell, .pen, .updown: 14
        case .down: 12
        default: 17
        }
    }

    var lineWidth: CGFloat { self == .pen ? 1.4 : 1.6 }

    var paths: [String] {
        switch self {
        case .home: ["M2.125 7.4375L8.5 2.125L14.875 7.4375", "M3.54167 6.72917V14.1667H13.4583V6.72917"]
        case .doc: ["M9.91667 2.125H4.25V14.875H12.75V4.95833L9.91667 2.125Z", "M9.91667 2.125V4.95833H12.75", "M6.375 8.5H10.625M6.375 11.3333H10.625"]
        case .layout: ["M13.4583 2.125H3.54167C2.75926 2.125 2.125 2.75926 2.125 3.54167V13.4583C2.125 14.2407 2.75926 14.875 3.54167 14.875H13.4583C14.2407 14.875 14.875 14.2407 14.875 13.4583V3.54167C14.875 2.75926 14.2407 2.125 13.4583 2.125Z",
                       "M2.125 6.375H14.875M6.375 6.375V14.875"]
        case .kanban: ["M13.4583 2.125H3.54167C2.75926 2.125 2.125 2.75926 2.125 3.54167V13.4583C2.125 14.2407 2.75926 14.875 3.54167 14.875H13.4583C14.2407 14.875 14.875 14.2407 14.875 13.4583V3.54167C14.875 2.75926 14.2407 2.125 13.4583 2.125Z",
                       "M5.66667 4.95833V9.91667M8.5 4.95833V7.79167M11.3333 4.95833V11.3333"]
        case .cal: ["M13.4583 3.54167H3.54167C2.75926 3.54167 2.125 4.17593 2.125 4.95833V13.4583C2.125 14.2407 2.75926 14.875 3.54167 14.875H13.4583C14.2407 14.875 14.875 14.2407 14.875 13.4583V4.95833C14.875 4.17593 14.2407 3.54167 13.4583 3.54167Z",
                    "M2.125 7.08333H14.875M5.66667 2.125V4.95833M11.3333 2.125V4.95833"]
        case .mic: ["M10.625 4.25C10.625 3.07639 9.6736 2.125 8.5 2.125C7.32639 2.125 6.375 3.07639 6.375 4.25V7.79167C6.375 8.96527 7.32639 9.91667 8.5 9.91667C9.6736 9.91667 10.625 8.96527 10.625 7.79167V4.25Z",
                    "M3.54167 7.79167C3.54167 9.1067 4.06406 10.3679 4.99393 11.2977C5.9238 12.2276 7.18497 12.75 8.5 12.75M8.5 12.75C9.81503 12.75 11.0762 12.2276 12.0061 11.2977C12.9359 10.3679 13.4583 9.1067 13.4583 7.79167M8.5 12.75V14.875"]
        case .brief: ["M13.4583 4.95833H3.54167C2.75926 4.95833 2.125 5.5926 2.125 6.375V12.75C2.125 13.5324 2.75926 14.1667 3.54167 14.1667H13.4583C14.2407 14.1667 14.875 13.5324 14.875 12.75V6.375C14.875 5.5926 14.2407 4.95833 13.4583 4.95833Z",
                      "M6.375 4.95833V2.83333H10.625V4.95833M2.125 9.20833H14.875"]
        case .folder: ["M2.125 4.25C2.125 4.06214 2.19963 3.88197 2.33247 3.74913C2.4653 3.61629 2.64547 3.54167 2.83333 3.54167H6.375L7.79167 4.95833H14.1667C14.3545 4.95833 14.5347 5.03296 14.6675 5.1658C14.8004 5.29864 14.875 5.47881 14.875 5.66667V13.4583C14.875 13.6462 14.8004 13.8264 14.6675 13.9592C14.5347 14.092 14.3545 14.1667 14.1667 14.1667H2.83333C2.64547 14.1667 2.4653 14.092 2.33247 13.9592C2.19963 13.8264 2.125 13.6462 2.125 13.4583V4.25Z"]
        case .side: ["M12 2.66667H4C2.89543 2.66667 2 3.5621 2 4.66667V11.3333C2 12.4379 2.89543 13.3333 4 13.3333H12C13.1046 13.3333 14 12.4379 14 11.3333V4.66667C14 3.5621 13.1046 2.66667 12 2.66667Z", "M6 2.66667V13.3333"]
        // 设计稿铃铛在 28 方钮里偏移 (7,7) 画在 14 格内，这里减去偏移。
        case .bell: ["M3 9.6667V6.3333C3 5.2725 3.4214 4.2551 4.1716 3.5049C4.9217 2.75476 5.9391 2.33333 7 2.33333C8.0609 2.33333 9.0783 2.75476 9.8284 3.5049C10.5786 4.2551 11 5.2725 11 6.3333V9.6667L12.3333 11H1.66667L3 9.6667Z",
                     "M5.6667 12.3333C5.6667 12.687 5.8071 13.0261 6.0572 13.2761C6.3072 13.5262 6.6464 13.6667 7 13.6667C7.3536 13.6667 7.6928 13.5262 7.9428 13.2761C8.1929 13.0261 8.3333 12.687 8.3333 12.3333"]
        case .pen: ["M7 2.33333H2.91667C2.76196 2.33333 2.61359 2.39479 2.50419 2.50419C2.39479 2.61358 2.33333 2.76196 2.33333 2.91667V11.0833C2.33333 11.238 2.39479 11.3864 2.50419 11.4958C2.61359 11.6052 2.76196 11.6667 2.91667 11.6667H11.0833C11.238 11.6667 11.3864 11.6052 11.4958 11.4958C11.6052 11.3864 11.6667 11.238 11.6667 11.0833V7",
                    "M10.2083 2.04167C10.4404 1.8096 10.7551 1.67923 11.0833 1.67923C11.2458 1.67923 11.4067 1.71124 11.5569 1.77342C11.707 1.83561 11.8434 1.92676 11.9583 2.04167C12.0732 2.15657 12.1644 2.29299 12.2266 2.44312C12.2888 2.59325 12.3208 2.75416 12.3208 2.91667C12.3208 3.07917 12.2888 3.24008 12.2266 3.39021C12.1644 3.54035 12.0732 3.67676 11.9583 3.79167L7 8.75L4.66667 9.33333L5.25 7L10.2083 2.04167Z"]
        case .updown: ["M4.08333 8.75L7 11.6667L9.91667 8.75M4.08333 5.25L7 2.33333L9.91667 5.25"]
        case .down: ["M3 4.5L6 7.5L9 4.5"]
        }
    }
}

/// 按设计稿画板绘制 `SideIcon`，颜色取前景色。
struct SideIconView: View {
    let icon: SideIcon
    var size: CGFloat? = nil

    var body: some View {
        let side = size ?? icon.box
        SideIconShape(icon: icon)
            .stroke(style: StrokeStyle(lineWidth: icon.lineWidth * side / icon.box, lineCap: .round, lineJoin: .round))
            .frame(width: side, height: side)
    }
}

struct SideIconShape: Shape {
    let icon: SideIcon
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for d in icon.paths { path.addPath(SVGPath.parse(d)) }
        let scale = min(rect.width, rect.height) / icon.box
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// 只解析 Figma 导出用到的绝对命令：M L H V C Z。
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        func flush() {
            var i = 0
            func take(_ n: Int) -> [CGFloat]? { guard i + n <= numbers.count else { return nil }; defer { i += n }; return Array(numbers[i..<i + n]) }
            switch command {
            case "Z":
                path.closeSubpath(); current = start
            case "M":
                guard let p = take(2) else { break }
                current = CGPoint(x: p[0], y: p[1]); start = current; path.move(to: current)
                while let p = take(2) { current = CGPoint(x: p[0], y: p[1]); path.addLine(to: current) }
            case "L":
                while let p = take(2) { current = CGPoint(x: p[0], y: p[1]); path.addLine(to: current) }
            case "H":
                while let p = take(1) { current.x = p[0]; path.addLine(to: current) }
            case "V":
                while let p = take(1) { current.y = p[0]; path.addLine(to: current) }
            case "C":
                while let p = take(6) {
                    current = CGPoint(x: p[4], y: p[5])
                    path.addCurve(to: current, control1: CGPoint(x: p[0], y: p[1]), control2: CGPoint(x: p[2], y: p[3]))
                }
            default: break
            }
            numbers.removeAll()
        }

        var token = ""
        func endNumber() { if let v = Double(token) { numbers.append(CGFloat(v)) }; token = "" }
        for ch in d {
            if "MLHVCZ".contains(ch) { endNumber(); flush(); command = ch }
            else if ch == " " || ch == "," { endNumber() }
            else if ch == "-" { endNumber(); token = "-" }
            else { token.append(ch) }
        }
        endNumber(); flush()
        return path
    }
}
