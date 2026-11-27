import DrawOfferCore
import SwiftUI

/// 展开的知识图谱（Figma 5:7·01.01–01.03、02A·10，Web `FeedbackHome` 展开态）：一张浅底圆角卡片，
/// 多段经历共用的技术在中间，经历和场次围成外圈，经历往里是业务、做成的事，只这段用到的技术挂在外侧；知识点都收着，右上角标 +N。
/// 点节点选中它：技术在原地展开考点，相连的亮、其余压淡，右上角出「聊一聊」；点空白收回。节点可以拖动、松手弹回，空白处拖动平移。
struct HomeGraphExpandedView: View {
    let graph: HomeGraph
    let stage: HomeGraphStage?
    /// 右边开着对话栏：图缩小一档
    let compact: Bool
    /// 对话栏正在聊的节点
    let chatKey: String?
    let collapse: () -> Void
    /// 在别的页面里单独打开（Web `KnowledgeGraphLayer`，没有对话栏）时传 nil：节点上不出「聊一聊」
    let chat: ((HomeChatTopic) -> Void)?

    @State private var selected: String?
    @State private var drags: [String: CGSize] = [:]
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero

    private var scale: CGFloat { compact ? 0.82 : 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFAFAF8))
            if let stage { canvas(stage).clipShape(RoundedRectangle(cornerRadius: 16)) } else { V3Loading("正在摆图谱…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            VStack(alignment: .leading, spacing: 4) {
                Text("你的知识图谱").font(V3.serif(20)).fontWeight(.semibold).foregroundStyle(V3.txt)
                Text("\(graph.points) 个知识点 · 来自 \(graph.sources.resumes) 份简历、\(graph.sources.mocks) 场练习、\(graph.sources.interviews) 场面试")
                    .font(V3.sans(12)).foregroundStyle(V3.fnt)
            }.padding(.leading, 32).padding(.top, 34).allowsHitTesting(false)
            Button(action: collapse) {
                HStack(spacing: 4) { Text("收起"); Image(systemName: "xmark").font(.system(size: 11, weight: .regular)) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 32).padding(.top, 40)
                .keyboardShortcut(.cancelAction)
            legend.font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 32).padding(.bottom, 18)
                .allowsHitTesting(false)
        }
        .onChange(of: chatKey) { _, key in if let key { selected = key } }
    }

    private var legend: some View {
        HStack(spacing: 0) {
            Text("橙色").foregroundStyle(V3.orange) + Text("还不牢 · ") + Text("蓝色").foregroundStyle(V3.blue) + Text("刚练稳 · ")
            Rectangle().fill(V3.txt).frame(width: 6, height: 6).padding(.trailing, 5)
            Text(compact ? "业务 · 左右拖动图谱看别处，点别的节点可以换成那一处的对话" : "业务 · 中间是多段经历共用的技术 · 点技术展开考点")
        }
    }

    // MARK: 画布

    private func canvas(_ stage: HomeGraphStage) -> some View {
        GeometryReader { geometry in
            // 上面留给标题和收起，下面留给图例；坐标横竖各自铺满这块，字号不随窗口放大
            let area = CGRect(x: 90 * scale, y: 112, width: max(200, geometry.size.width - 180 * scale), height: max(160, geometry.size.height - 112 - 70))
            let shown = stage.shown(selected: selected)
            let lit = selected.map(stage.lit)
            // 排布只知道圆点，不知道字多宽：按字宽把叠着的推开、避开标题和收起（窄的时候知识点才不会压在技术名上）
            let size = geometry.size
            let placed = HomeGraphStage.untangle(graph.nodes.filter { shown.contains($0.id) }.compactMap { node in
                guard let spot = stage.full[node.id] else { return nil }
                let half = HomeGraphStage.footprintSize(node, core: stage.core.contains(node.id), scale: scale, picked: selected == node.id)
                return HomeGraphStage.Footprint(key: node.id, kind: node.kind, x: area.midX + spot.x * area.width, y: area.midY + spot.y * area.height,
                                                halfWidth: half.halfWidth, halfHeight: half.halfHeight)
            }, bounds: .init(left: 16, top: 16, right: size.width - 16, bottom: size.height - 48),
               blocks: [.init(left: 0, top: 0, right: 360, bottom: 96), .init(left: size.width - 130, top: 0, right: size.width, bottom: 64)])
            let at = { (id: String) -> CGPoint? in
                guard let point = placed[id] else { return nil }
                let drag = drags[id] ?? .zero
                return CGPoint(x: point.x + pan.width + drag.width, y: point.y + pan.height + drag.height)
            }
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { selected = chatKey }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { pan = CGSize(width: max(-420, min(420, panBase.width + $0.translation.width)), height: max(-260, min(260, panBase.height + $0.translation.height))) }
                        .onEnded { _ in panBase = pan })
                Canvas { context, _ in
                    for line in stage.visibleLines(shown: shown, selected: selected) {
                        guard let a = at(line.a), let b = at(line.b) else { continue }
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        let touching = selected != nil && (line.a == selected || line.b == selected)
                        let color = touching ? Color(hex: 0x87867F) : Color(hex: 0xE2E0D8).opacity(selected == nil ? 1 : 0.5)
                        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: touching ? 1.2 : 1, dash: line.dashed ? [3, 4] : []))
                    }
                }.allowsHitTesting(false)
                ForEach(graph.nodes.filter { shown.contains($0.id) }) { node in
                    if let point = at(node.id) {
                        nodeView(node, stage: stage, shown: shown, dim: lit.map { !$0.contains(node.id) } ?? false)
                            .position(point)
                    }
                }
            }
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45), value: selected)
        }
    }

    private func nodeView(_ node: HomeGraph.Node, stage: HomeGraphStage, shown: Set<String>, dim: Bool) -> some View {
        let on = selected == node.id
        let more = stage.hidden(node.id, shown: shown, selected: selected)
        let color: Color = node.tone == .hot ? V3.orange : node.tone == .new ? V3.blue : V3.txt
        // 名字单独成一个读屏元素，右上角的「聊一聊」才能单独点到
        return HomeGraphLabel(node: node, large: true, core: stage.core.contains(node.id), scale: scale, picked: on)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node.label)
            .accessibilityHint(node.kind == .technology ? "点一下展开考点" : "点一下选中")
            .accessibilityAddTraits(.isButton)
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(Color(hex: 0xFAFAF8).opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottom) {
                if on { Rectangle().fill(color).frame(height: 1.5).padding(.horizontal, 4).offset(y: 1) }
            }
            // 收着的下级个数（+N）挂在右上角，不占节点的位置
            .overlay(alignment: .topTrailing) {
                if more > 0 {
                    // 零宽的框钉在右上角，字从框的左上角往右下溢出：挂在节点外侧，不挤动节点
                    Text("+\(more)").font(V3.sans(10 * scale)).foregroundStyle(Color(hex: 0xA5A39B)).fixedSize()
                        .frame(width: 0, height: 0, alignment: .topLeading).offset(x: -1, y: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if on, chatKey != node.id, let chat {
                    Button { chat(HomeChatTopic(key: node.id, name: node.label, state: node.chatState, tone: node.tone)) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left").font(.system(size: 10))
                            Text("聊一聊").font(V3.sans(11))
                        }.foregroundStyle(V3.fnt).fixedSize().contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .frame(width: 0, height: 0, alignment: .bottomLeading).offset(x: 2, y: 4)
                }
            }
            .opacity(dim ? 0.3 : 1)
            .contentShape(Rectangle())
            .onTapGesture { selected = selected == node.id ? chatKey : node.id }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { drags[node.id] = $0.translation }
                .onEnded { _ in withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { drags[node.id] = nil } })
            .animation(.easeOut(duration: 0.16), value: on)
    }
}
