import DrawOfferCore
import SwiftUI

/// 展开的知识图谱（Figma 02A·10 ①–④，Web `FeedbackHome` 展开态）：
/// 一张浅底圆角卡片，中间「长期记忆」，技术围成一圈，知识点挂在各自的技术外侧；
/// 点节点放大并画一条线，右上角出「聊一聊」；点空白收回；节点可以拖动、松手弹回，空白处拖动平移图谱。
struct HomeGraphExpandedView: View {
    let graph: HomeGraph
    /// 右边开着对话栏：图缩小一档
    let compact: Bool
    /// 对话栏正在聊的节点
    let chatKey: String?
    let collapse: () -> Void
    let chat: (HomeChatTopic) -> Void

    @State private var selected: String?
    @State private var drags: [String: CGSize] = [:]
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero

    private var shown: [HomeGraph.Node] { graph.nodes.filter { $0.kind == .technology || $0.kind == .point } }
    private var scale: CGFloat { compact ? 0.82 : 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFAFAF8))
            canvas.clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("你的知识图谱").font(V3.serif(20)).fontWeight(.semibold).foregroundStyle(V3.txt)
                Text("\(graph.points) 个知识点 · 来自 \(graph.sources.resumes) 份简历、\(graph.sources.mocks) 场练习、\(graph.sources.interviews) 场面试")
                    .font(V3.sans(12)).foregroundStyle(V3.fnt)
            }.padding(.leading, 32).padding(.top, 34).allowsHitTesting(false)
            Button(action: collapse) {
                HStack(spacing: 6) { Text("收起"); Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .medium)) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 32).padding(.top, 40)
                .keyboardShortcut(.cancelAction)
            Text(legend).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 32).padding(.bottom, 18)
                .allowsHitTesting(false)
        }
        .onChange(of: chatKey) { _, key in if let key { selected = key } }
    }

    private var legend: AttributedString {
        var text = AttributedString("橙色还不牢 · 蓝色刚练稳 · " + (compact ? "左右拖动图谱看别处，点别的节点可以换成那一处的对话" : "节点可以拖动，松手弹回"))
        if let orange = text.range(of: "橙色") { text[orange].foregroundColor = V3.orange }
        if let blue = text.range(of: "蓝色") { text[blue].foregroundColor = V3.blue }
        return text
    }

    // MARK: 画布

    private var canvas: some View {
        GeometryReader { geometry in
            let placed = HomeRadial.place(nodes: shown, edges: graph.edges, size: geometry.size, compact: compact)
            let at = { (id: String) -> CGPoint? in
                guard let point = placed.at[id] else { return nil }
                let drag = drags[id] ?? .zero
                return CGPoint(x: point.x + pan.width + drag.width, y: point.y + pan.height + drag.height)
            }
            let center = CGPoint(x: placed.center.x + pan.width, y: placed.center.y + pan.height)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { selected = chatKey }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { pan = CGSize(width: max(-420, min(420, panBase.width + $0.translation.width)), height: max(-260, min(260, panBase.height + $0.translation.height))) }
                        .onEnded { _ in panBase = pan })
                Canvas { context, _ in
                    for line in placed.lines {
                        let from = line.from == nil ? center : at(line.from!)
                        guard let from, let to = at(line.to) else { continue }
                        var path = Path(); path.move(to: from); path.addLine(to: to)
                        let lit = selected != nil && (line.to == selected || line.from == selected)
                        context.stroke(path, with: .color(lit ? Color(hex: 0xA5A39B) : Color(hex: 0xE2E0D8)), lineWidth: 1)
                    }
                }.allowsHitTesting(false)
                Text("长期记忆").font(V3.serif(26 * scale)).fontWeight(.semibold).foregroundStyle(V3.txt).fixedSize()
                    .position(center).allowsHitTesting(false)
                ForEach(shown) { node in
                    if let point = at(node.id) {
                        nodeView(node).position(point)
                    }
                }
            }
        }
    }

    private func nodeView(_ node: HomeGraph.Node) -> some View {
        let on = selected == node.id
        let big = node.kind == .technology
        let color = tint(node)
        let size = (big ? 17.0 : 13.0) * scale * (on ? 1.22 : 1)
        return Text(node.short).font(V3.sans(size, weight: big || node.tone != .plain || on ? .medium : .regular)).foregroundStyle(color).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                if on { Rectangle().fill(node.tone == .plain ? V3.txt : color).frame(height: 2).padding(.horizontal, 4).offset(y: 1) }
            }
            .overlay(alignment: .topTrailing) {
                if on, chatKey != node.id {
                    Button { chat(HomeChatTopic(key: node.id, name: node.label, state: state(node), tone: node.tone)) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left").font(.system(size: 10))
                            Text("聊一聊").font(V3.sans(11))
                        }.foregroundStyle(V3.fnt).fixedSize().contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .alignmentGuide(.trailing) { $0[.leading] - 2 }
                        .alignmentGuide(.top) { $0[.bottom] - 6 }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selected = node.id }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { drags[node.id] = $0.translation }
                .onEnded { _ in withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { drags[node.id] = nil } })
            .animation(.easeOut(duration: 0.16), value: on)
            .accessibilityLabel(node.label)
            .accessibilityHint("点一下选中，再点聊一聊")
    }

    private func tint(_ node: HomeGraph.Node) -> Color {
        switch node.tone {
        case .hot: V3.orange
        case .new: V3.blue
        case .plain: node.kind == .technology ? V3.txt : Color(hex: 0x87867F)
        }
    }

    private func state(_ node: HomeGraph.Node) -> String {
        switch node.tone {
        case .hot: node.overstated ? "写高了" : "还不牢"
        case .new: "刚练稳"
        case .plain: ""
        }
    }
}

/// 展开图谱的摆放：中心「长期记忆」，技术按椭圆等分一圈，知识点在各自技术外侧扇形散开。
enum HomeRadial {
    struct Line { let from: String?; let to: String }
    struct Placed { var center: CGPoint; var at: [String: CGPoint]; var lines: [Line] }

    static func place(nodes: [HomeGraph.Node], edges: [HomeGraph.Edge], size: CGSize, compact: Bool) -> Placed {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.53)
        let techs = nodes.filter { $0.kind == .technology }
            .sorted { ($0.size, $1.name) > ($1.size, $0.name) }.prefix(8).map { $0 }
        let ids = Set(nodes.map(\.id))
        var parent: [String: String] = [:]
        for edge in edges where edge.kind == "TP" && ids.contains(edge.dst) && techs.contains(where: { $0.id == edge.src }) {
            if parent[edge.dst] == nil { parent[edge.dst] = edge.src }
        }
        let k: CGFloat = compact ? 0.8 : 1
        let rx = min(size.width * 0.27, 300 * k), ry = min(size.height * 0.28, 215 * k)
        var at: [String: CGPoint] = [:]
        var lines: [Line] = []
        for (index, tech) in techs.enumerated() {
            let angle = -Double.pi / 2 + (Double(index) + 0.35) * 2 * .pi / Double(max(techs.count, 1)) + jitter(tech.id, 0.12)
            let point = CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry)
            at[tech.id] = point
            lines.append(Line(from: nil, to: tech.id))
            let kids = nodes.filter { $0.kind == .point && parent[$0.id] == tech.id }
            for (j, kid) in kids.enumerated() {
                let spread = (Double(j) - Double(kids.count - 1) / 2) * (kids.count > 3 ? 0.55 : 0.7)
                let theta = angle + spread + jitter(kid.id, 0.1)
                let radius = (118 + Double(j % 2) * 34) * Double(k)
                at[kid.id] = clamp(CGPoint(x: point.x + cos(theta) * radius * 1.15, y: point.y + sin(theta) * radius * 0.85), size)
                lines.append(Line(from: tech.id, to: kid.id))
            }
        }
        // 没挂在任何技术下的知识点：沿外圈均匀放
        let loose = nodes.filter { $0.kind == .point && parent[$0.id] == nil }
        for (index, node) in loose.enumerated() {
            let angle = -Double.pi / 2 + (Double(index) + 0.5) * 2 * .pi / Double(max(loose.count, 1))
            at[node.id] = clamp(CGPoint(x: center.x + cos(angle) * rx * 1.3, y: center.y + sin(angle) * ry * 1.3), size)
            lines.append(Line(from: nil, to: node.id))
        }
        return Placed(center: center, at: at, lines: lines)
    }

    private static func clamp(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 60), max(60, size.width - 60)), y: min(max(point.y, 90), max(90, size.height - 56)))
    }

    private static func jitter(_ key: String, _ span: Double) -> Double {
        var value: UInt32 = 2166136261
        for unit in key.utf16 { value = (value ^ UInt32(unit)) &* 16777619 }
        return (Double(value % 1000) / 1000 - 0.5) * 2 * span
    }
}
