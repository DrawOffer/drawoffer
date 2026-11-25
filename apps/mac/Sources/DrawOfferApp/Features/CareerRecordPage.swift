import DrawOfferCore
import SwiftUI

/// 07.04 粘贴面试记录 / 07.05 面试记录阅读页（Figma 07 页 84:761、84:762；Web `progress/RecordPage.tsx` + `RecordReader.tsx`）。
/// 页头同投递详情：左上统一返回、右上 ⋯，一行衬线标题 + 这一页唯一的黑按钮。
/// 看：只呈现原话，题与题细线分开，衬线问题 + 完整回答，追问缩进带竖线；右边目录只有题号和题目，读到的那题变蓝。
/// 粘贴：贴文字，点「拆成问题」回到上一页，后台拆好直接存成面试记录。
struct CareerRecordPage: View {
    enum Mode { case record, paste }
    let application: JSONValue
    let station: CareerStation
    let session: JSONValue
    let mode: Mode
    let splitting: Bool
    let splitError: String?
    let backLabel: String
    /// 「生成复盘 · 30 积分」；价格读不到时只写「生成复盘」。
    var reviewLabel = "生成复盘"
    let back: () -> Void
    let split: (String) -> Void
    let generateReview: () -> Void
    /// ⋯ 里的「重新粘贴记录」「查看这一轮的资料」；不传时不出现。
    var repaste: (() -> Void)? = nil
    var openMaterials: (() -> Void)? = nil
    @State private var paste = ""
    @State private var active = 0

    private var questions: [RecordQuestion] { InterviewRecord.parse(session.text("questions_markdown")) }

    var body: some View {
        CareerSubpageFrame { width in
            VStack(alignment: .leading, spacing: 0) {
                CareerSubpageHead(backLabel: backLabel, back: back, title: title, menu: menuItems) {
                    if mode == .record && (!questions.isEmpty || splitting) {
                        Button(reviewLabel, action: generateReview).buttonStyle(PDButtonStyle(kind: .primary)).disabled(splitting)
                    }
                    if mode == .paste {
                        Button("拆成问题") { split(paste.trimmingCharacters(in: .whitespacesAndNewlines)) }.buttonStyle(PDButtonStyle(kind: .primary))
                            .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || splitting)
                    }
                }
                if mode == .paste { pasteBody.padding(.top, 40) }
                else if splitting { splittingBody }
                else if questions.isEmpty {
                    Text("还没有问题。").font(V3.sans(13)).foregroundStyle(PD.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RecordReaderView(questions: questions, active: $active).padding(.top, 36)
                }
            }
        }
        .foregroundStyle(V3.txt)
    }

    private var title: String {
        if mode == .paste { return "把\(station.short)的记录贴进来。" }
        if splitting { return "正在整理\(station.short)的记录。" }
        return "\(station.short)问了 \(questions.count) 道题。"
    }

    private var menuItems: [CareerSubpageMenuItem] {
        var items: [CareerSubpageMenuItem] = []
        if mode == .record, !splitting, let repaste { items.append(.init(title: questions.isEmpty ? "粘贴面试记录" : "重新粘贴记录", action: repaste)) }
        if let openMaterials { items.append(.init(title: "查看这一轮的资料", action: openMaterials)) }
        return items
    }

    private var pasteBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let splitError {
                notice(splitError + " 原文已经保留在下面。")
            } else if !questions.isEmpty {
                notice("拆好后会替换现在的 \(questions.count) 道题。")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { paste }, set: { paste = String($0.prefix(30_000)) }))
                    .font(V3.sans(14)).lineSpacing(12).scrollContentBackground(.hidden)
                    .padding(.horizontal, 19).padding(.vertical, 22)
                    .accessibilityLabel("粘贴面试文字")
                if paste.isEmpty {
                    Text("比如：问了订单服务，我讲了拆单和预占；追问对账任务挂了怎么办……").font(V3.sans(14)).foregroundStyle(V3.fnt2)
                        .padding(.horizontal, 24).padding(.vertical, 22).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
            HStack(alignment: .top, spacing: 24) {
                Text("笔记、聊天记录都行，不用整理格式。拆题在后台进行，可以先离开。").frame(maxWidth: .infinity, alignment: .leading)
                Text("\(paste.count.formatted()) 字").monospacedDigit()
            }
            .font(V3.sans(12)).foregroundStyle(Color(hex: 0x9E9B91)).padding(.top, 16)
        }
        .padding(.bottom, 32)
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(V3.sans(13, weight: .medium)).foregroundStyle(Color(hex: 0xB26114))
            .padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(V3.orangeSoft, in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 16)
    }

    private var splittingBody: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在把你贴的文字拆成问题").font(V3.sans(15, weight: .medium))
            Text("一般 20–40 秒。可以先回去做别的，拆好后会直接存成面试记录，这里也会自动刷新。").font(V3.sans(13)).foregroundStyle(PD.body).multilineTextAlignment(.center)
        }.frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 面试记录阅读（07.05，Web `RecordReader`）：左边所有题连着读（自带滚动），右边细目录固定不动、读到的那题变蓝。
struct RecordReaderView: View {
    let questions: [RecordQuestion]
    @Binding var active: Int
    var missing: (RecordQuestion, Int) -> String? = { _, _ in nil }

    var body: some View {
        ScrollViewReader { proxy in
            // 稿 07.05：正文滚动区 660 宽（问答 600 + 右侧留白），距目录 75
            HStack(alignment: .top, spacing: 75) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(questions.enumerated()), id: \.offset) { position, item in
                            block(item, position: position).id(position)
                                .background(GeometryReader { geometry in Color.clear.preference(key: RecordOffsets.self, value: [position: geometry.frame(in: .named("record")).minY]) })
                        }
                    }
                    .frame(maxWidth: 600, alignment: .leading).padding(.bottom, 96)
                }
                .scrollIndicators(.never)
                .coordinateSpace(name: "record")
                .onPreferenceChange(RecordOffsets.self) { offsets in
                    // 读到哪一题：最后一个顶边越过阅读区顶部（留 40）的题
                    active = offsets.filter { $0.value <= 40 }.map(\.key).max() ?? 0
                }
                .frame(maxWidth: 660, alignment: .leading).layoutPriority(1)
                index(proxy).frame(width: 300, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 一道题：题号，衬线问题，完整回答，追问（缩进一格、左边细竖线）。
    private func block(_ item: RecordQuestion, position: Int) -> some View {
        let follows = item.followUps.filter { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty || !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            Text(String(format: "%02d", position + 1)).font(.system(size: 12, weight: .medium)).foregroundStyle(PD.mute).frame(height: 18)
            Text(item.question.trimmingCharacters(in: .whitespaces).nonEmptyValue ?? "（没记下问题）").font(V3.serif(20)).foregroundStyle(V3.txt)
                .lineHeight(20, 30, .serif).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if item.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(missing(item, position) ?? "这道题没记下回答").font(V3.sans(14)).foregroundStyle(PD.mute)
            } else { paragraphs(item.answer) }
            if let reply = item.reply, !reply.trimmingCharacters(in: .whitespaces).isEmpty { follow("面试官", question: nil, answer: reply) }
            ForEach(Array(follows.enumerated()), id: \.offset) { _, entry in
                follow("追问", question: entry.question.trimmingCharacters(in: .whitespaces).nonEmptyValue, answer: entry.answer)
            }
        }
        .padding(.top, position == 0 ? 0 : 40).padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if position > 0 { Rectangle().fill(V3.cl).frame(height: 1) } }
        .accessibilityElement(children: .contain).accessibilityLabel("第 \(position + 1) 题")
    }

    private func paragraphs(_ text: String) -> some View {
        let parts = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part).font(V3.sans(15)).foregroundStyle(PD.body).lineHeight(15, 28).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func follow(_ label: String, question: String?, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(V3.sans(12, weight: .medium)).foregroundStyle(PD.mute).frame(height: 18)
            if let question { Text(question).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt).lineHeight(16, 26).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("这道追问没记下回答").font(V3.sans(14)).foregroundStyle(PD.mute)
            } else { paragraphs(answer) }
        }
        .padding(.leading, 18).padding(.vertical, 2)
        .overlay(alignment: .leading) { Rectangle().fill(V3.cl).frame(width: 2) }
        .padding(.top, 4)
    }

    /// 右侧目录：「N 题」，一行题号 + 题目；读到的那题变蓝。悬停只把字变深，不加底色。
    private func index(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(questions.count) 题").font(V3.sans(13)).foregroundStyle(Color(hex: 0x6C6C65)).frame(height: 20).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { position, item in
                        CareerRecordIndexRow(number: position + 1, title: item.question.trimmingCharacters(in: .whitespaces).nonEmptyValue ?? "（没记下问题）", on: position == active) {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(position, anchor: .top) }
                            active = position
                        }
                    }
                }
            }.scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("目录")
    }
}

private struct CareerRecordIndexRow: View {
    let number: Int
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", number)).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? PD.blue : PD.mute).frame(width: 18, alignment: .leading)
                Text(title).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? PD.blue : hover ? V3.txt : PD.body).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: 20).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 投递详情下级页（05.03 笔试题、07.04 粘贴、07.05 记录）共用的外框：左右留白与投递详情一致，高度撑满窗口。
struct CareerSubpageFrame<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View {
        GeometryReader { geometry in
            // 稿：内容区 1178 宽时左右各 63
            let gutter = max(max(40, geometry.size.width * 0.0535), (geometry.size.width - 1200) / 2)
            let width = max(0, geometry.size.width - gutter * 2)
            content(width)
                .frame(width: width, height: max(0, geometry.size.height - 40), alignment: .topLeading)
                .padding(.horizontal, gutter).padding(.top, 40)
        }
        .background(.white)
    }
}

/// 下级页页头（07.04 / 07.05 / 05.03）：左上统一返回「← 公司 · 岗位」，右上 ⋯；下面一行衬线标题 + 按钮。
struct CareerSubpageHead<Actions: View>: View {
    let backLabel: String
    let back: () -> Void
    let title: String
    var menu: [CareerSubpageMenuItem] = []
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                CareerJourneyTextButton(title: "← " + backLabel, color: Color(hex: 0x6C6C65), action: back).accessibilityLabel("返回" + backLabel)
                Spacer()
                if !menu.isEmpty {
                    Menu {
                        ForEach(Array(menu.enumerated()), id: \.offset) { _, item in Button(item.title, action: item.action) }
                    } label: { Text("⋯").font(.system(size: 16, weight: .medium)).foregroundStyle(PD.body).frame(width: 20, height: 19) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("更多操作")
                }
            }.frame(height: 19)
            HStack(alignment: .center, spacing: 24) {
                Text(title).font(V3.serif(36)).foregroundStyle(V3.txt).lineHeight(36, 48, .serif).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) { actions() }
            }.padding(.top, 28)
        }
    }
}


/// 下级页右上 ⋯ 里的一项。
struct CareerSubpageMenuItem { let title: String; let action: () -> Void }

struct RecordOffsets: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}
