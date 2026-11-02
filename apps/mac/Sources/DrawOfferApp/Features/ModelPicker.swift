import AppKit
import DrawOfferCore
import SwiftUI

/// 模型选择，对齐 Web `assistant/ModelPicker.tsx`：触发按钮（厂商图标 + 名称 + ⌄）与 248 宽的“选择模型”弹层，
/// 悬停一行在左侧显示介绍、能力 / 速度档位与平均每轮积分；额度不可用的模型仍能悬停查看但不能选。
struct ModelPicker: View {
    let models: [JSONValue]
    let selectedID: String?
    var loading = false
    var disabled = false
    /// 首页地平线提示行里的样式：10px、跟随提示行颜色、不显示 ⌄。
    var inline = false
    var compact = false
    let select: (String) -> Void

    @State private var open = false
    @State private var hoveredID: String?

    private var selected: JSONValue? { models.first { $0.text("id") == selectedID } }
    private var label: String { (selected?.text("name")).flatMap { $0.isEmpty ? nil : $0 } ?? "选择模型" }

    var body: some View {
        Button { hoveredID = nil; open.toggle() } label: {
            HStack(spacing: inline ? 4 : 5) {
                if let selected { ModelIcon(name: selected.text("name"), size: inline ? 10 : (compact ? 13 : 15)).saturation(inline ? 0 : 1).opacity(inline ? 0.7 : 1) }
                Text(loading ? "正在读取模型" : label).lineLimit(1).truncationMode(.tail)
                if !compact && !inline { Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.sub) }
            }
            .font(inline ? .system(size: 10) : .system(size: compact ? 11 : 12.5, weight: compact ? .medium : .regular))
            .foregroundStyle(inline ? Color(hex: 0x9B978C) : (compact ? V3.fnt : Color(hex: 0x33332F)))
            .frame(maxWidth: 240).fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(loading).help(selected?.text("name") ?? "")
        .accessibilityLabel(label)
        .popover(isPresented: $open, arrowEdge: .top) { menu }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择模型").font(.system(size: 12)).foregroundStyle(Color(hex: 0x474D56))
                .frame(height: 34, alignment: .bottomLeading).padding(.horizontal, 10).padding(.bottom, 4)
            if models.isEmpty {
                Text(loading ? "正在读取模型" : "当前没有可用模型").font(.system(size: 12)).foregroundStyle(V3.fnt).padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(models, id: \.self) { row($0) } }.padding(.vertical, 2)
                }.frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(7).frame(width: 248)
        .overlay(alignment: .topLeading) {
            if let hovered = models.first(where: { $0.text("id") == hoveredID }) {
                ModelHoverCard(model: hovered).offset(x: -248 - 15).allowsHitTesting(false)
            }
        }
        .onHover { if !$0 { hoveredID = nil } }
        .accessibilityElement(children: .contain).accessibilityLabel("选择模型")
    }

    private func row(_ model: JSONValue) -> some View {
        let id = model.text("id"), active = id == selectedID, unavailable = model["available"]?.bool == false
        return Button {
            guard !unavailable else { return }
            open = false
            select(id)
        } label: {
            HStack(spacing: 8) {
                ModelIcon(name: model.text("name"), size: 18)
                Text(model.text("name")).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if unavailable { Text("当前额度不可用").font(.system(size: 11)).foregroundStyle(V3.sub) }
                if active { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(V3.txt) }
            }
            .font(.system(size: 12)).foregroundStyle(Color(hex: 0x25292F))
            .padding(.leading, 10).padding(.trailing, 8).frame(height: 36)
            .background(active || hoveredID == id ? Color(hex: 0xF4F5F7) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(unavailable ? 0.5 : 1).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { if $0 { hoveredID = id } }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// 悬停卡（Figma 25.1）：名称与状态、介绍、能力 / 速度细条、平均每轮积分。
private struct ModelHoverCard: View {
    let model: JSONValue
    private static let abilities = ["一般", "够用", "较强", "很强", "最强"]
    private static let speeds = ["很慢", "较慢", "中等", "较快", "很快"]

    var body: some View {
        let turn = model["turn"]
        let status = model["isFreeTier"]?.bool == true ? "free" : model["available"]?.bool == false ? "locked" : "member"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ModelIcon(name: model.text("name"), size: 16)
                Text(model.text("name")).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0x1F2329)).lineLimit(1)
                Spacer(minLength: 0)
                // 对话不扣积分时人人都能用，不标会员
                if turn?.text("basis") != "free" {
                    Text(["free": "免费可用", "member": "会员", "locked": "需开通会员"][status]!).font(.system(size: 11))
                        .foregroundStyle(status == "free" ? Color(hex: 0x3F6FD8) : status == "locked" ? Color(hex: 0xC2410C) : Color(hex: 0xA0A6AE))
                }
            }
            if case let intro = model.text("chatIntro").trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
                Text(intro).font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B7280)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            let ability = Int(model["abilityLevel"]?.numberValue ?? 0), speed = Int(model["speedLevel"]?.numberValue ?? 0)
            if ability > 0 || speed > 0 {
                VStack(spacing: 8) {
                    if ability > 0 { level("能力", ability, Self.abilities) }
                    if speed > 0 { level("速度", speed, Self.speeds) }
                }.padding(.top, 12)
            }
            if let turn {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("平均每轮").font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B7280)).frame(maxWidth: .infinity, alignment: .leading)
                    let points = Self.turnPoints(turn["points"]?.stringValue)
                    if turn.text("basis") == "free" { Text("不扣积分").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0x1F2329)) }
                    else if let points {
                        Text(turn.text("basis") == "fixed" ? points : "约 \(points)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0x1F2329))
                        Text("积分").font(.system(size: 11)).foregroundStyle(Color(hex: 0xA0A6AE))
                    } else { Text("按实际用量").font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B7280)) }
                }.padding(.top, 12)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(width: 248, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE6E8EB)))
        .shadow(color: Color(red: 15 / 255, green: 23 / 255, blue: 41 / 255).opacity(0.08), radius: 10, y: 6)
    }

    private func level(_ label: String, _ value: Int, _ names: [String]) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B7280)).frame(width: 28, alignment: .leading)
            // 渐变铺满整条轨道，档位只决定露出多少
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xEEF0F3))
                LinearGradient(stops: [.init(color: Color(hex: 0xB9C47A), location: 0), .init(color: Color(hex: 0xE0B45A), location: 0.41667),
                                       .init(color: Color(hex: 0xD9824A), location: 0.83333), .init(color: Color(hex: 0xB8513F), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) { Capsule().frame(width: 120 * Double(min(5, value)) / 5) }
            }.frame(width: 120, height: 4)
            Spacer(minLength: 0)
            Text(names[min(5, max(1, value)) - 1]).font(.system(size: 11)).foregroundStyle(Color(hex: 0xA0A6AE))
        }
    }

    /// 「约 1.4」：不到 10 保留一位小数，10 以上取整；没有价格时为 nil。
    static func turnPoints(_ raw: String?) -> String? {
        guard let raw, let value = Double(raw), value.isFinite else { return nil }
        if value >= 10 { return String(Int(value.rounded())) }
        let one = (value * 10).rounded() / 10
        return one == one.rounded() ? String(Int(one)) : String(one)
    }
}

/// 厂商图标：按模型名认出厂商（与 Web `modelVendor` 同规则），认不出时用 spark。
struct ModelIcon: View {
    let name: String
    var size: CGFloat = 18

    static func vendor(_ name: String) -> String? {
        let value = name.lowercased()
        if value.range(of: #"gpt|(^|[^a-z])o[1-9]|openai"#, options: .regularExpression) != nil { return "openai" }
        for (key, words) in [("claude", ["claude"]), ("gemini", ["gemini"]), ("deepseek", ["deepseek"]), ("kimi", ["kimi", "moonshot"]), ("grok", ["grok"])]
        where words.contains(where: value.contains) { return key }
        return nil
    }

    private static let cache = NSCache<NSString, NSImage>()
    private static func image(_ vendor: String) -> NSImage? {
        if let hit = cache.object(forKey: vendor as NSString) { return hit }
        guard let url = Bundle.module.url(forResource: vendor, withExtension: "svg", subdirectory: "Models"), let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: vendor as NSString)
        return image
    }

    var body: some View {
        if let vendor = Self.vendor(name), let image = Self.image(vendor) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle").font(.system(size: size * 0.8)).foregroundStyle(V3.sub).frame(width: size, height: size)
        }
    }
}
