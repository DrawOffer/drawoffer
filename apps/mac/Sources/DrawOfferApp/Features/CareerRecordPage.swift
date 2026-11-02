import DrawOfferCore
import SwiftUI

/// Web `progress/RecordPage.tsx` + `RecordReader.tsx`：面试记录整页。
/// 看：所有题连着读，我的回答在右、面试官追问在左，右侧细目录跟着读到的题高亮；
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
    let back: () -> Void
    let split: (String) -> Void
    let generateReview: () -> Void
    @State private var paste = ""
    @State private var active = 0

    private var questions: [RecordQuestion] { InterviewRecord.parse(session.text("questions_markdown")) }

    var body: some View {
        GeometryReader { geometry in
            let gutter = V3Page<EmptyView>.gutter(card: geometry.size.width)
            let width = min(max(0, geometry.size.width - gutter * 2), V3Page<EmptyView>.maxWidth(card: geometry.size.width))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        head
                        if mode == .paste { pasteBody }
                        else if splitting { splittingBody }
                        else if questions.isEmpty { Text("还没有问题。").font(V3.sans(13)).foregroundStyle(Color(hex: 0x9E9B91)).frame(maxWidth: .infinity).padding(.top, 80) }
                        else { reader(proxy) }
                    }
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, gutter).padding(.top, 52).padding(.bottom, 80)
                }
                .coordinateSpace(name: "record")
                .onPreferenceChange(RecordOffsets.self) { offsets in
                    // 读到哪一题：最后一个顶边越过目录顶部的题
                    let line: CGFloat = 60
                    active = offsets.filter { $0.value <= line }.map(\.key).max() ?? 0
                }
            }
        }
        .foregroundStyle(V3.txt)
        .onAppear { if mode == .paste { paste = splitError != nil ? paste : "" } }
    }

    private var head: some View {
        let start = CareerApplication.date(session.text("start_at"))
        let when = start.map { "\(CareerDeckFormat.monthDay($0)) \(CareerDeckFormat.weekday($0))" } ?? CareerDeckFormat.monthDay(station.start)
        let meta: [String?] = mode == .paste || splitting ? [when, "粘贴文字"]
            : [when, session.text("transcript_source") == "transcription" ? "录音转写" : nil, "\(questions.count) 道题"]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: back) {
                    HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text(backLabel) }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("返回" + backLabel)
                Text("/")
                Text("面试记录")
            }.font(V3.sans(14)).foregroundStyle(V3.fnt).frame(height: 20).padding(.bottom, 12)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(application.text("company_name_snapshot")) · \(application.text("job_title_snapshot"))").font(V3.sans(13)).frame(height: 21)
                    Text("\(station.short)的面试记录").font(V3.serif(30)).frame(height: 42).padding(.bottom, 6)
                    Text(meta.compactMap { $0 }.joined(separator: "  ·  ")).font(V3.sans(13)).foregroundStyle(Color(hex: 0x7D7A72)).frame(height: 21)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    if mode == .record && (!questions.isEmpty || splitting) {
                        Button("生成 AI 复盘", action: generateReview).buttonStyle(PDButtonStyle(kind: .primary)).disabled(splitting)
                    }
                    if mode == .paste {
                        Text("拆题按实际用量扣积分").font(V3.sans(12)).foregroundStyle(Color(hex: 0x9E9B91))
                        Button("拆成问题") { split(paste.trimmingCharacters(in: .whitespacesAndNewlines)) }.buttonStyle(PDButtonStyle(kind: .primary))
                            .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || splitting)
                    }
                }
            }.padding(.bottom, 26)
        }
    }

    private var pasteBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let splitError { Text(splitError + " 原文已经保留在下面。").font(V3.sans(13)).foregroundStyle(Color(hex: 0xA35A12)) }
            else if !questions.isEmpty { Text("拆好后会替换现在的 \(questions.count) 道题。").font(V3.sans(13)).foregroundStyle(Color(hex: 0xA35A12)) }
            Text("随便贴：面试后的笔记、和朋友的聊天记录都行，不用整理格式").font(V3.sans(13)).foregroundStyle(PD.body)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { paste }, set: { paste = String($0.prefix(30_000)) }))
                    .font(V3.sans(14)).scrollContentBackground(.hidden).padding(10)
                    .accessibilityLabel("粘贴面试文字")
                if paste.isEmpty {
                    Text("比如：问了订单服务，我讲了拆单和预占；追问对账任务挂了怎么办……").font(V3.sans(14)).foregroundStyle(V3.fnt2).padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 360)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
            HStack(alignment: .top) {
                Text("点“拆成问题”后会回到资料，AI 在后台按问题拆开、把回答和追问归到对应的题下面；拆好后直接存成面试记录。").font(V3.sans(12)).foregroundStyle(PD.mute)
                Spacer(minLength: 16)
                Text("\(paste.count) 字").font(V3.sans(12)).foregroundStyle(PD.mute)
            }
        }
    }

    private var splittingBody: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在把你贴的文字拆成问题").font(V3.sans(15, weight: .medium))
            Text("一般 20–40 秒。可以先回资料做别的，拆好后会直接存成面试记录，这里也会自动刷新。").font(V3.sans(13)).foregroundStyle(PD.body).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.top, 80)
    }

    private func reader(_ proxy: ScrollViewProxy) -> some View {
        RecordReaderView(questions: questions, active: $active, proxy: proxy)
    }
}

/// 面试记录阅读（Web `progress/RecordReader.tsx`）：所有题连着读 + 右侧细目录。求职进度的面试记录、模拟面试的「翻看面试记录」共用。
/// 外层 ScrollView 要命名坐标空间 `record` 并按 `RecordOffsets` 算出 `active`。
struct RecordReaderView: View {
    let questions: [RecordQuestion]
    @Binding var active: Int
    let proxy: ScrollViewProxy
    var missing: (RecordQuestion, Int) -> String? = { _, _ in nil }

    var body: some View { reader(proxy) }

    private func reader(_ proxy: ScrollViewProxy) -> some View {
        let list = questions
        return HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { position, item in
                    block(item, position: position).id(position)
                        .background(GeometryReader { geometry in Color.clear.preference(key: RecordOffsets.self, value: [position: geometry.frame(in: .named("record")).minY]) })
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            index(list, proxy: proxy).frame(width: 200).padding(.top, 20)
        }
    }

    private func block(_ item: RecordQuestion, position: Int) -> some View {
        let follows = item.followUps.filter { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty || !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Text(String(format: "%02d", position + 1)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(position == active ? PD.blueText : Color(hex: 0x9E9B91))
                    .frame(width: 26, height: 26).background(position == active ? Color(hex: 0xEEF3FD) : Color(hex: 0xF6F6F3), in: RoundedRectangle(cornerRadius: 7))
                Text(item.question.trimmingCharacters(in: .whitespaces).nonEmptyValue ?? "（没记下问题）").font(V3.sans(17, weight: .medium)).lineSpacing(5).frame(minHeight: 26).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                if item.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bubble(missing(item, position) ?? "这道题没记下回答", me: true, missing: true)
                } else { bubble(item.answer, me: true) }
                if let reply = item.reply, !reply.trimmingCharacters(in: .whitespaces).isEmpty { bubble(reply, me: false) }
                ForEach(Array(follows.enumerated()), id: \.offset) { _, follow in
                    if !follow.question.trimmingCharacters(in: .whitespaces).isEmpty { bubble(follow.question, me: false) }
                    if !follow.answer.trimmingCharacters(in: .whitespaces).isEmpty { bubble(follow.answer, me: true) }
                }
            }.padding(.leading, 40)
        }
        .padding(.vertical, 28)
        .overlay(alignment: .bottom) { Rectangle().fill(V3.cl).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("第 \(position + 1) 题")
    }

    private func bubble(_ text: String, me: Bool, missing: Bool = false) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: me ? 16 : 6, bottomTrailingRadius: me ? 6 : 16, topTrailingRadius: 16)
        return HStack {
            if me { Spacer(minLength: 0) }
            // `.rp-say`：14px / 24 行高，没记回答时 13px / 22
            Text(text).font(V3.sans(missing ? 13 : 14)).foregroundStyle(missing ? Color(hex: 0x9E9B91) : V3.txt).lineSpacing(missing ? 5 : 7)
                .frame(minHeight: missing ? 22 : 24)
                .padding(.horizontal, 16).padding(.vertical, missing ? 11 : 12)
                .background(missing ? Color.clear : me ? Color(hex: 0xEEF3FD) : Color(hex: 0xF6F6F3), in: shape)
                .overlay { if missing { shape.stroke(V3.cl, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
                .frame(maxWidth: me ? 520 : 420, alignment: me ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !me { Spacer(minLength: 0) }
        }
    }

    private func index(_ list: [RecordQuestion], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("目录").font(V3.sans(12, weight: .medium)).foregroundStyle(Color(hex: 0x7D7A72))
                Spacer()
                Text("\(list.count) 道题").font(V3.sans(12)).foregroundStyle(Color(hex: 0x9E9B91))
            }.frame(height: 18).padding(.bottom, 6)
            ForEach(Array(list.enumerated()), id: \.offset) { position, item in
                let on = position == active
                Button { withAnimation { proxy.scrollTo(position, anchor: .top) }; active = position } label: {
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", position + 1)).font(.system(size: 11, weight: .medium)).foregroundStyle(on ? PD.blueText : Color(hex: 0x9E9B91))
                        Text(item.question.trimmingCharacters(in: .whitespaces).nonEmptyValue ?? "（没记下问题）").lineLimit(1)
                            .foregroundStyle(on ? PD.blueText : position < active ? V3.txt : Color(hex: 0x7D7A72))
                        Spacer(minLength: 0)
                        if !item.followUps.isEmpty { Circle().fill(V3.orange).frame(width: 6, height: 6).accessibilityLabel("被追问过") }
                    }
                    .font(V3.sans(12, weight: on ? .medium : .regular)).frame(height: 18)
                    .padding(.vertical, 5).padding(.leading, on ? 11 : 12).padding(.trailing, 4)
                    .overlay(alignment: .leading) { Rectangle().fill(on ? PD.blue : V3.cl).frame(width: on ? 2 : 1) }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if list.contains(where: { !$0.followUps.isEmpty }) {
                HStack(spacing: 6) { Circle().fill(V3.orange).frame(width: 6, height: 6); Text("被追问过") }
                    .font(V3.sans(11)).foregroundStyle(Color(hex: 0x9E9B91)).padding(.top, 14).padding(.leading, 12)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("目录")
    }
}

struct RecordOffsets: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Web `StationCard.PrepDialog`：560 宽；勾选、增加、生成准备清单。
struct CareerPrepSheet: View {
    let session: JSONValue
    let busy: Bool
    let save: ([JSONValue]) -> Void
    let generate: () -> Void
    let close: () -> Void
    @State private var draft: String?

    private static let category = ["intro": "自我介绍", "project": "项目", "technical": "技术", "system_design": "系统设计", "behavior": "行为", "company": "公司", "other": "其他"]

    var body: some View {
        let items = session["prep_items"]?.items ?? []
        let done = items.filter { $0["done"]?.bool == true }.count
        let canGenerate = session.text("status") == "scheduled" && (session["prep_generated_at"] ?? .null) == .null
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("准备清单").font(V3.serif(20)).frame(height: 28)
                Text(items.isEmpty ? "还没有准备清单" : "完成 \(done) / \(items.count)").font(V3.sans(12.5)).foregroundStyle(PD.body)
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 8)
            Rectangle().fill(Color(hex: 0xECEAE4)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if busy && items.isEmpty { Text("正在按岗位要求和简历生成…").font(V3.sans(12.5)).foregroundStyle(PD.body).padding(.top, 14) }
                    if !busy && items.isEmpty && canGenerate {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("按这一站的类型、岗位要求和你的简历生成").font(V3.sans(13, weight: .medium))
                                Text("可以随时增删").font(V3.sans(12)).foregroundStyle(PD.mute)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("生成准备清单", action: generate).buttonStyle(PDButtonStyle(kind: .primary)).disabled(busy)
                        }.padding(.horizontal, 18).padding(.vertical, 16).background(Color(hex: 0xF4F7FD), in: RoundedRectangle(cornerRadius: 14))
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let on = item["done"]?.bool == true
                        HStack(spacing: 10) {
                            Button { save(toggled(items, index)) } label: {
                                Circle().stroke(on ? PD.blue : Color(hex: 0xC3D3F0), lineWidth: 1.4).background(Circle().fill(on ? PD.blue : .white))
                                    .overlay { if on { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white) } }
                                    .frame(width: 14, height: 14).frame(width: 22, height: 22).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(busy).accessibilityLabel(item.text("title")).accessibilityAddTraits(on ? .isSelected : [])
                            Text(Self.category[item.text("category")] ?? "其他").font(V3.sans(11, weight: .medium)).foregroundStyle(PD.blueText).frame(width: 54, alignment: .leading)
                            Text(item.text("title")).font(V3.sans(13, weight: .medium)).foregroundStyle(on ? PD.mute : PD.ink).strikethrough(on).frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.text("reason")).font(V3.sans(12)).foregroundStyle(PD.mute).lineLimit(1)
                        }
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xEEF2F9)).frame(height: 1) }
                    }
                    if draft != nil {
                        HStack(spacing: 10) {
                            Spacer().frame(width: 22)
                            Text("其他").font(V3.sans(11, weight: .medium)).foregroundStyle(PD.blueText).frame(width: 54, alignment: .leading)
                            TextField("比如：复习项目里的分片方案", text: Binding(get: { draft ?? "" }, set: { draft = String($0.prefix(80)) }))
                                .textFieldStyle(.plain).font(V3.sans(13)).padding(.horizontal, 10).frame(height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xCDDCF5)))
                                .onSubmit { add(items) }
                                .accessibilityLabel("新的准备事项")
                        }.frame(minHeight: 44)
                    }
                }.padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 20)
            }.frame(maxHeight: 560)
            Rectangle().fill(Color(hex: 0xECEAE4)).frame(height: 1)
            HStack(spacing: 10) {
                Button("+ 添加一项") { if draft == nil { draft = "" } else { add(items) } }
                    .buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(PD.ink).disabled(busy || items.count >= 12)
                Spacer()
                Button("关闭") { if let draft, !draft.trimmingCharacters(in: .whitespaces).isEmpty { add(items) }; close() }.buttonStyle(PDButtonStyle())
            }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 20)
        }
        .frame(width: 560).foregroundStyle(PD.ink)
    }

    private func toggled(_ items: [JSONValue], _ index: Int) -> [JSONValue] {
        items.enumerated().map { position, item in
            guard position == index, case .object(var fields) = item else { return item }
            fields["done"] = .bool(item["done"]?.bool != true)
            return .object(fields)
        }
    }

    private func add(_ items: [JSONValue]) {
        let title = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft = nil
        guard !title.isEmpty else { return }
        save(items + [.object(["title": .string(String(title.prefix(80))), "category": .string("other"), "reason": .null, "done": .bool(false)])])
    }
}
