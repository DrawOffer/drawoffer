import AppKit
import DrawOfferCore
import SwiftUI

/// 投递详情各块的画法（Figma 07 页 04–09 分区，Web `progress/journey.tsx` + `journey.css`）。
/// 文案与状态在 Core `CareerJourney`；数据、弹窗和跳转在 `CareerApplicationDetailView`。
enum CareerJourneyStyle {
    static let ink = Color(hex: 0x1D1D1B)
    static let body = Color(hex: 0x55554F)
    static let sub = Color(hex: 0x6C6C65)
    static let mute = Color(hex: 0x96968F)
    static let line = Color(hex: 0xE4E4E0)
    static let track = Color(hex: 0xC9C9C3)
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xD9822B)
    static let check = Color(hex: 0xB9B9B3)
}

private typealias JS = CareerJourneyStyle

/// `.jy-more` / `.jy-top-link`：灰色文字按钮，悬停变墨色（不加底色）。
struct CareerJourneyTextButton: View {
    let title: String
    var size: CGFloat = 13
    var color: Color = JS.body
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(V3.sans(size)).foregroundStyle(hover ? JS.ink : color).lineLimit(1).fixedSize().contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// `.jy-link`：蓝色文字链，悬停加下划线。
struct CareerJourneyLink: View {
    let title: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(V3.sans(size)).foregroundStyle(JS.blue).underline(hover).lineLimit(1).fixedSize().contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - 这一步（各分区上半左侧）

struct CareerJourneyHero: View {
    let job: String
    let step: CareerJourneyStep
    /// 这一轮的资料（07.03）：只在有的时候出现在标题下。
    let files: [JSONValue]
    let sideHasBlack: Bool
    let disabled: Bool
    let act: (CareerJourneyAction) -> Void
    let copy: (String) -> Void
    let openFile: (JSONValue) -> Void
    let addFromComputer: () -> Void
    let addFromLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 眉题：公司 · 岗位 + 蓝色阶段
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                Text(job).foregroundStyle(JS.ink).lineLimit(1)
                Text(step.stage).foregroundStyle(JS.blue).lineLimit(1).fixedSize()
            }.font(V3.sans(13, weight: .medium)).frame(minHeight: 16)
            // 衬线结论标题 36 / 48
            Text(step.title).font(V3.serif(36)).foregroundStyle(JS.ink).lineHeight(36, 48)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if let desc = step.desc, !desc.isEmpty {
                Text(desc).font(V3.sans(15)).foregroundStyle(JS.body).lineHeight(15, 25).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if let place = step.place { placeRow(place).padding(.top, 26) }
            if !files.isEmpty { filesRow.padding(.top, 22) }
            if step.primary != nil || step.secondary != nil {
                HStack(spacing: 10) {
                    if let primary = step.primary { button(primary, black: !sideHasBlack) }
                    if let secondary = step.secondary {
                        button(secondary, black: step.primary == nil && !sideHasBlack && secondary.action != .backToNow)
                    }
                }.padding(.top, 30)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func button(_ item: CareerJourneyButton, black: Bool) -> some View {
        Button(item.label) { act(item.action) }.buttonStyle(PDButtonStyle(kind: black ? .primary : .normal)).disabled(disabled)
    }

    private func placeRow(_ place: CareerJourneyPlace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "link").font(.system(size: 13)).foregroundStyle(JS.mute)
            if let url = place.url {
                PlaceLink(text: place.text, url: url)
            } else {
                Text(place.text).font(V3.sans(14)).foregroundStyle(JS.ink).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .leading)
            }
            CareerJourneyTextButton(title: "复制", color: JS.sub) { copy(place.copy) }
            if place.editable {
                Text("·").font(V3.sans(13)).foregroundStyle(JS.mute)
                CareerJourneyTextButton(title: "修改安排", color: JS.sub) { act(.reschedule) }
            }
        }.frame(minHeight: 17)
    }

    private struct PlaceLink: View {
        let text: String
        let url: URL
        @State private var hover = false
        var body: some View {
            Button { NSWorkspace.shared.open(url) } label: {
                Text(text).font(V3.sans(14)).foregroundStyle(JS.ink).underline(hover).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            }.buttonStyle(.plain).onHover { hover = $0 }
        }
    }

    private var filesRow: some View {
        FlowLayout(spacing: 8) {
            Text("资料").font(V3.sans(12.5)).foregroundStyle(JS.mute).frame(height: 28).padding(.trailing, 4)
            ForEach(files, id: \.self) { asset in
                Button { openFile(asset) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc").font(.system(size: 11))
                        Text(asset.text("original_file_name")).lineLimit(1).truncationMode(.middle)
                    }
                    .font(V3.sans(12.5)).foregroundStyle(JS.body).padding(.horizontal, 10).frame(maxWidth: 220).frame(height: 28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(JS.line))
                }.buttonStyle(.plain).help(asset.text("original_file_name"))
            }
            Menu {
                Button("从电脑选", action: addFromComputer)
                Button("从资料库选", action: addFromLibrary)
            } label: {
                Text("＋ 添加").font(V3.sans(12.5)).foregroundStyle(JS.sub).padding(.horizontal, 10).frame(height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(JS.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

// MARK: - 右侧公共件

/// `.jy-side-head`：灰色小标题（strong 时墨色 16），右侧可带文字按钮。
struct CareerJourneySideHead: View {
    let title: String
    var strong = false
    var count: String? = nil
    var more: String? = nil
    var onMore: () -> Void = {}
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(V3.sans(strong ? 16 : 13, weight: strong ? .medium : .regular)).foregroundStyle(strong ? JS.ink : JS.sub)
                if let count { Text(count).font(V3.number(12.5, weight: .medium)).foregroundStyle(JS.mute) }
            }
            Spacer(minLength: 0)
            if let more { CareerJourneyTextButton(title: more, action: onMore) }
        }
    }
}

/// `.jy-drop`：虚线入口（录音、生成清单、笔试题）。
struct CareerJourneyDrop<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    var busy = false
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(JS.sub).frame(height: 22).padding(.bottom, 8)
            Text(title).font(V3.sans(17, weight: .medium)).foregroundStyle(JS.ink).multilineTextAlignment(.center).lineHeight(17, 24)
            if busy { CareerJourneyProgress().frame(maxWidth: 240).padding(.top, 8).padding(.bottom, 4) }
            Text(text).font(V3.sans(12.5)).foregroundStyle(JS.body).multilineTextAlignment(.center).lineHeight(12.5, 19).frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions() }.padding(.top, 16)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 38)
        .background(Color(hex: 0xFAFAF8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(busy ? JS.line : Color(hex: 0xD8D8D3), style: StrokeStyle(lineWidth: 1, dash: busy ? [] : [4, 3])))
    }
}

/// `.jy-progress`：转写中的细进度条，蓝色小段来回走。
struct CareerJourneyProgress: View {
    @State private var phase = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(JS.line)
                Capsule().fill(JS.blue).frame(width: geometry.size.width * 0.36)
                    .offset(x: phase ? geometry.size.width : -geometry.size.width * 0.36)
            }.clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { phase = true } }
    }
}

/// `.jy-stats`：三个大数字。
struct CareerJourneyStats: View {
    let items: [(value: Int, label: String, orange: Bool)]
    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.value)").font(V3.number(30, weight: .medium)).foregroundStyle(item.orange ? JS.orange : JS.ink).frame(height: 34)
                    Text(item.label).font(V3.sans(12.5)).foregroundStyle(JS.sub)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// `.jy-card`：题目卡片（问到的题、没答到位的地方）。
struct CareerJourneyCard: View {
    let title: String
    let meta: String
    let quote: String?
    let link: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(V3.sans(17, weight: .medium)).foregroundStyle(JS.ink).lineLimit(1).frame(height: 22)
            Text(meta).font(V3.sans(12.5)).foregroundStyle(JS.sub).padding(.top, 8)
            if let quote { Text(quote).font(V3.sans(12.5)).foregroundStyle(JS.body).lineLimit(2).lineHeight(12.5, 17).padding(.top, 5) }
            CareerJourneyLink(title: link, action: action).padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 15)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(JS.line))
    }
}

// MARK: - 右侧：投的这份简历（04.01 / 04.02 / 04.03）

struct CareerJourneyResumeSide: View {
    let application: JSONValue
    let pending: Bool
    let api: any APIClient
    let open: () -> Void
    let pick: () -> Void
    @State private var match: JobMatch?

    var body: some View {
        let title = application.text("resume_title_snapshot")
        let label = pending ? "准备投的简历" : "投的这份简历"
        HStack(alignment: .center, spacing: 28) {
            CareerJourneyPaper(empty: title.isEmpty)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(V3.sans(13, weight: .medium)).foregroundStyle(JS.sub).frame(height: 16)
                if title.isEmpty {
                    Text(pending ? "还没选简历" : "还没记是哪一份").font(V3.serif(20)).foregroundStyle(JS.sub).frame(height: 30).padding(.top, 10)
                    Text(pending ? "记录投递时选一份，之后的准备和复盘都会参考它。" : "补上投的那份简历，复盘会更准。")
                        .font(V3.sans(14)).foregroundStyle(JS.body).lineHeight(14, 23).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    CareerJourneyTextButton(title: "选一份简历 ›", action: pick).padding(.top, 16)
                } else {
                    Text(title).font(V3.serif(20)).foregroundStyle(JS.ink).lineLimit(1).truncationMode(.tail).frame(height: 30).padding(.top, 10).help(title)
                    if let note = note, !note.isEmpty {
                        Text(note).font(V3.sans(14)).foregroundStyle(JS.body).lineHeight(14, 23).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                    HStack(spacing: 24) {
                        if !application.text("resume_id").isEmpty { CareerJourneyTextButton(title: "打开简历 ›", action: open) }
                        if pending { CareerJourneyTextButton(title: "换一份 ›", action: pick) }
                    }.padding(.top, 16)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(label)
        .task(id: application.text("job_description_id") + application.text("resume_id")) { await loadMatch() }
    }

    private var note: String? {
        if let match, match.ready, let score = match.score {
            let gaps = match.gaps.prefix(2)
            return gaps.isEmpty ? "和这个岗位匹配 \(score) 分。" : "和这个岗位匹配 \(score) 分，还缺 \(gaps.joined(separator: "、"))。"
        }
        if pending { return "投递时会用这一份，也可以换。" }
        let applied = application.text("applied_at")
        return [CareerDeck.source(application), applied.isEmpty ? nil : CareerFormat.monthDay(applied) + " 投递"].compactMap { $0 }.joined(separator: " · ")
    }

    private func loadMatch() async {
        let job = application.text("job_description_id"), resume = application.text("resume_id")
        guard !job.isEmpty, !resume.isEmpty else { match = nil; return }
        let result = try? await api.careerRequest(path: "/api/job-descriptions/\(job)/match", method: "GET", query: ["resume_id": resume], body: nil)
        match = JobMatch(result?["match"])
    }
}

/// `.jy-paper`：一张简历纸的缩略（没选简历时线条变淡）。
struct CareerJourneyPaper: View {
    var empty = false
    var body: some View {
        // 线条：名字、副标题，然后三段（段标题 + 若干行），尺寸照稿
        let groups: [[CGFloat]] = [[100, 92, 64], [100, 96, 80, 52], [100, 70]]
        VStack(alignment: .leading, spacing: 0) {
            bar(58, 6, Color(hex: 0x3D3D39))
            bar(84, 3, Color(hex: 0xD6D6D1)).padding(.top, 6)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, rows in
                bar(28, 3, Color(hex: 0x9A9A93)).padding(.top, index == 0 ? 15 : 13)
                ForEach(Array(rows.enumerated()), id: \.offset) { row, width in
                    bar(width, 2.5, Color(hex: 0xE1E1DC)).padding(.top, row == 0 ? 6 : 4.5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 17)
        .frame(width: 132, height: 176, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(JS.line))
        .shadow(color: .black.opacity(empty ? 0 : 0.06), radius: 9, y: 6)
        .opacity(empty ? 0.6 : 1)
        .accessibilityHidden(true)
    }
    private func bar(_ width: CGFloat, _ height: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(empty ? Color(hex: 0xE1E1DC).opacity(0.45) : color).frame(width: width, height: height)
    }
}

// MARK: - 右侧：准备清单（05.02 / 06.x / 08.01–08.03）

struct CareerJourneyPrepSide: View {
    let short: String
    let session: JSONValue?
    let busy: Bool
    let cost: String?
    let save: ([JSONValue]) -> Void
    let generate: () -> Void
    let practice: (String) -> Void
    @State private var draft = ""
    @State private var showDone = false

    private static let practiceCategories: Set<String> = ["technical", "system_design", "project"]
    private static let categoryLabels = ["technical": "技术知识", "system_design": "系统设计", "project": "项目深挖", "behavioral": "行为面试", "company": "公司调研", "logistics": "面试安排"]

    var body: some View {
        let title = "\(short)前要准备的"
        VStack(alignment: .leading, spacing: 14) {
            if let session {
                let items = session["prep_items"]?.items ?? []
                let done = items.filter { $0["done"]?.bool == true }.count
                CareerJourneySideHead(title: title, strong: true, count: items.isEmpty ? nil : "\(done) / \(items.count)")
                if items.isEmpty {
                    if session["prep_generated_at"] == nil || session["prep_generated_at"] == .null {
                        // 08.02：还没有清单时，右侧的「生成准备清单」是唯一的黑按钮
                        CareerJourneyDrop(icon: "checklist", title: busy ? "正在生成准备清单…" : "还没有准备清单",
                                          text: "按岗位要求、你的简历和上一轮复盘，列出这一轮前该补的几件事。每场面试只能生成一次。") {
                            Button("生成准备清单", action: generate).buttonStyle(PDButtonStyle(kind: .primary)).disabled(busy)
                            if let cost { Text(cost).font(V3.sans(12)).foregroundStyle(JS.mute) }
                        }
                    } else {
                        Text("清单已经清空了，可以自己加几条。").font(V3.sans(14)).foregroundStyle(JS.sub).lineHeight(14, 23)
                    }
                } else {
                    list(items)
                }
                addRow(items)
            } else {
                CareerJourneySideHead(title: title, strong: true)
                Text("安排好时间以后，可以按岗位要求和你的简历生成准备清单。").font(V3.sans(14)).foregroundStyle(JS.sub).lineHeight(14, 23).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    @ViewBuilder private func list(_ items: [JSONValue]) -> some View {
        let order = Array(items.enumerated())
        let open = order.filter { $0.element["done"]?.bool != true }
        let closed = order.filter { $0.element["done"]?.bool == true }
        let fold = items.count > 6
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(open, id: \.offset) { row($0.offset, $0.element, items) }
            if !fold || showDone { ForEach(closed, id: \.offset) { row($0.offset, $0.element, items) } }
        }
        if fold {
            // 08.03：清单很长时右侧高度固定，超出在框内滚动、底部渐隐
            ScrollView { rows.padding(.trailing, 14) }.frame(maxHeight: 342)
                .mask(VStack(spacing: 0) { Color.black; LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24) })
            if !closed.isEmpty {
                Button { showDone.toggle() } label: {
                    HStack {
                        Text("已完成 \(closed.count) 项").foregroundStyle(JS.mute)
                        Spacer()
                        Text(showDone ? "收起" : "展开 ›").foregroundStyle(JS.sub)
                    }.font(V3.sans(13)).padding(.top, 11).contentShape(Rectangle())
                    .overlay(alignment: .top) { Rectangle().fill(JS.line).frame(height: 1) }
                }.buttonStyle(.plain)
            }
        } else { rows }
    }

    private func row(_ index: Int, _ item: JSONValue, _ items: [JSONValue]) -> some View {
        let done = item["done"]?.bool == true
        let category = item.text("category")
        let detail = [item.text("source_label").nonEmptyValue, item.text("reason").nonEmptyValue, category != "other" ? Self.categoryLabels[category] : nil].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .center, spacing: 14) {
            Button { toggle(index, items) } label: {
                ZStack {
                    Circle().fill(done ? JS.ink : .white)
                    Circle().stroke(done ? JS.ink : JS.check, lineWidth: 1.5)
                    if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                }.frame(width: 18, height: 18).contentShape(Circle())
            }.buttonStyle(.plain).disabled(busy).accessibilityLabel(item.text("title")).accessibilityAddTraits(done ? .isSelected : [])
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text("title")).font(V3.sans(14)).foregroundStyle(done ? JS.mute : JS.ink).strikethrough(done, color: JS.mute).lineLimit(2)
                if !detail.isEmpty { Text(detail).font(V3.sans(12)).foregroundStyle(done ? JS.check : JS.mute).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !done && Self.practiceCategories.contains(category) {
                CareerJourneyLink(title: "去练这一处 ›", size: 12.5) { practice(item.text("title")) }
            }
        }.padding(.vertical, 11)
    }

    private func toggle(_ index: Int, _ items: [JSONValue]) {
        save(items.enumerated().map { position, item in
            guard position == index, case .object(var fields) = item else { return item }
            fields["done"] = .bool(item["done"]?.bool != true); return .object(fields)
        })
    }

    private func addRow(_ items: [JSONValue]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(JS.mute)
            TextField("", text: $draft, prompt: Text(items.isEmpty ? "不生成，自己加一条" : "加一条准备事项").foregroundStyle(JS.mute))
                .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(JS.ink)
                .disabled(busy || items.count >= 20)
                .onSubmit {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    save(items + [.object(["title": .string(String(text.prefix(80))), "category": .string("other"), "reason": .null, "done": .bool(false)])])
                    draft = ""
                }
                .accessibilityLabel("加一条准备事项")
        }
        .padding(.horizontal, 14).frame(height: 39)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(JS.line))
    }
}

// MARK: - 右侧：这场面试的记录（07.01 / 07.02）

struct CareerJourneyRecordEntrySide: View {
    let state: CareerJourney.RecordState
    let busy: Bool
    let upload: () -> Void
    let paste: () -> Void
    let retry: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CareerJourneySideHead(title: "这场面试的记录")
            switch state {
            case .transcribing(let file, let minutes):
                CareerJourneyDrop(icon: "waveform", title: "正在把「\(file)」转成文字",
                                  text: minutes.map { "大约 \($0) 分钟，好了会自动按问题拆好，可以先离开。" } ?? "好了会自动按问题拆好，可以先离开。", busy: true) { EmptyView() }
            case .failed(let file, let id):
                CareerJourneyDrop(icon: "exclamationmark.circle", title: "「\(file)」没能转成文字", text: "可以重新转一次，或者换成粘贴文字。") {
                    Button("重新转文字") { retry(id) }.buttonStyle(PDButtonStyle(kind: .primary)).disabled(busy)
                    Button("粘贴文字", action: paste).buttonStyle(PDButtonStyle())
                }
            default:
                CareerJourneyDrop(icon: "mic", title: "把录音拖到这里", text: "自动转文字、按问题拆好；没录音也可以贴一段回忆。") {
                    Button("上传录音", action: upload).buttonStyle(PDButtonStyle(kind: .primary)).disabled(busy)
                    Button("粘贴文字", action: paste).buttonStyle(PDButtonStyle())
                }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("这场面试的记录")
    }
}

// MARK: - 右侧：面试中问到（07.06）

struct CareerJourneyQuestionsSide: View {
    let session: JSONValue
    let detail: JSONValue?
    let api: any APIClient
    let open: (Int) -> Void
    @State private var fetched: (markdown: String, groups: [JSONValue])?
    /// 每份记录只请求一次考点，失败或记录又改了都不重试，页面照常按题显示。
    @MainActor private static var requested = Set<String>()

    var body: some View {
        let markdown = CareerJourney.markdown(session, detail)
        let questions = InterviewRecord.parse(markdown)
        let stored = (detail?["session"]?["record_topics"]?.items).flatMap { $0.isEmpty ? nil : $0 }
            ?? (session["record_topics"]?.items).flatMap { $0.isEmpty ? nil : $0 }
            ?? (fetched?.markdown == markdown ? fetched?.groups : nil)
        let cards = CareerJourney.topicCards(questions, groups: stored)
        VStack(alignment: .leading, spacing: 14) {
            CareerJourneySideHead(title: "面试中问到 · \(questions.count) 题", more: "看完整记录 ›") { open(0) }
            VStack(spacing: 12) {
                ForEach(cards) { card in
                    CareerJourneyCard(title: card.title, meta: card.meta, quote: card.quote, link: card.many ? "看这几题 ›" : "看这一题 ›") { open(card.position) }
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("面试中问到")
        .task(id: session.text("id") + ":" + markdown) {
            let key = session.text("id") + ":" + markdown
            let list = CareerJourney.topicQuestions(questions)
            guard stored == nil, !list.isEmpty, !Self.requested.contains(key) else { return }
            Self.requested.insert(key)
            if let result = try? await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/record-topics", method: "POST", query: [:],
                                                         body: .object(["questions": .array(list.map(JSONValue.string))])),
               let groups = result["session"]?["record_topics"]?.items, !groups.isEmpty {
                fetched = (markdown, groups)
            }
        }
    }
}

// MARK: - 右侧：复盘结论（07.07）、这次留下的（09.05 / 09.06）

struct CareerJourneyWeakList: View {
    let points: [CareerJourney.WeakPoint]
    let practice: (String) -> Void
    var body: some View {
        VStack(spacing: 12) {
            ForEach(points) { point in
                CareerJourneyCard(title: point.title, meta: point.detail, quote: point.quote, link: "去模拟面试练这一处 ›") { practice(point.title) }
            }
        }
    }
}

struct CareerJourneyReviewSide: View {
    let session: JSONValue
    let detail: JSONValue?
    let openReview: () -> Void
    let practice: (String) -> Void
    var body: some View {
        let report = session["review_report"] ?? .null
        let points = CareerJourney.weakPoints(session)
        let asked = CareerReview.isV2(report)
            ? (report["questions"]?.items ?? []).filter { !["reverse", "follow_up"].contains($0.text("kind")) }.count
            : InterviewRecord.parse(CareerJourney.markdown(session, detail)).count
        VStack(alignment: .leading, spacing: 14) {
            CareerJourneyStats(items: [(asked, "问到的题", false), (max(0, asked - points.count), "答到位", false), (points.count, "没答到位", points.count > 0)])
            if points.isEmpty {
                Text(CareerJourney.reviewDetail(session).nonEmptyValue ?? "每道题都答到了位。").font(V3.sans(14)).foregroundStyle(JS.sub).lineHeight(14, 23)
            } else {
                CareerJourneySideHead(title: "没答到位的地方", more: points.count > 2 ? "还有 \(points.count - 2) 处 ›" : nil, onMore: openReview).padding(.top, 30)
                CareerJourneyWeakList(points: Array(points.prefix(2)), practice: practice)
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("复盘结论")
    }
}

struct CareerJourneyLeftSide: View {
    let deck: CareerDeck
    let details: [String: JSONValue]
    let openReview: () -> Void
    let practice: (String) -> Void
    var body: some View {
        let interviews = deck.stations.filter { $0.kind == .interview && $0.session.map { $0.text("status") != "cancelled" } == true }.count
        let recorded = deck.stations.reduce(0) { sum, station in
            guard let session = station.session else { return sum }
            return sum + InterviewRecord.parse(CareerJourney.markdown(session, details[session.text("id")])).count
        }
        let points = deck.stations.flatMap { CareerJourney.weakPoints($0.session, stageShort: $0.short) }
        VStack(alignment: .leading, spacing: 14) {
            CareerJourneyStats(items: [(deck.days, "天", false), (interviews, "场面试", false), (recorded, "道题记下来", false)])
            if !points.isEmpty {
                CareerJourneySideHead(title: "下次还要补的", more: points.count > 2 ? "全部 \(points.count) 处 ›" : nil, onMore: openReview).padding(.top, 30)
                CareerJourneyWeakList(points: Array(points.prefix(2)), practice: practice)
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("这次留下的")
    }
}

// MARK: - 右侧：笔试题（05.02 之后）

struct CareerJourneyWrittenSide: View {
    let session: JSONValue
    let detail: JSONValue?
    let open: () -> Void
    let add: () -> Void
    var body: some View {
        let questions = detail?["session"]?["written_questions"]?.items ?? session["written_questions"]?.items ?? []
        let wrong = questions.filter { $0.text("correctness") == "wrong" }.count
        let correct = questions.filter { $0.text("correctness") == "correct" }.count
        VStack(alignment: .leading, spacing: 14) {
            CareerJourneySideHead(title: "笔试题", more: questions.isEmpty ? nil : "查看全部 ›", onMore: open)
            if questions.isEmpty {
                CareerJourneyDrop(icon: "doc", title: "还没有题目", text: "上传题目截图或文档，AI 读出题目后可以逐题标答对、答错。") {
                    Button("添加笔试题", action: add).buttonStyle(PDButtonStyle())
                }
            } else {
                CareerJourneyStats(items: [(questions.count, "道题", false), (correct, "答对", false), (wrong, "答错", wrong > 0)])
                VStack(spacing: 0) {
                    ForEach(Array(questions.prefix(4).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Text(item.display("question_no")).font(V3.number(12, weight: .medium)).foregroundStyle(JS.mute).frame(width: 24, alignment: .leading)
                            Text(item.text("question_text")).font(V3.sans(13.5)).foregroundStyle(JS.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Circle().fill(item.text("correctness") == "wrong" ? JS.orange : .clear).frame(width: 6, height: 6).frame(width: 8)
                                .accessibilityLabel(item.text("correctness") == "wrong" ? "答错" : "")
                        }
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(JS.line).frame(height: 1) }
                    }
                }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("笔试题")
    }
}

// MARK: - 右侧：Offer 与 OC（09.01 / 09.02 / 09.04）

struct CareerJourneyOfferSide: View {
    let application: JSONValue
    let oc: Bool
    let accepted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if oc {
                let at = application.text("oc_communicated_at")
                CareerJourneySideHead(title: "电话里说的")
                salary(application.text("oc_salary_text").nonEmptyValue ?? "没说薪资", note: "口头，以正式 Offer 为准")
                rows([("预计入职", application.text("oc_start_text").nonEmptyValue), ("联系人", application.text("oc_contact").nonEmptyValue),
                      ("沟通时间", at.isEmpty ? nil : CareerFormat.monthDay(at))])
            } else {
                let due = CareerJourney.offerDate(application.text("offer_reply_due_on"))
                CareerJourneySideHead(title: "这份 Offer")
                salary(CareerJourney.offerSalary(application) ?? "还没填薪资", note: CareerJourney.offerYearly(application))
                rows([("入职", CareerJourney.dotDate(application.text("offer_start_on"))), ("试用期", application.text("offer_probation").nonEmptyValue),
                      ("地点", application.text("offer_base_location").nonEmptyValue),
                      accepted ? ("接受日期", application.text("terminated_at").isEmpty ? "—" : CareerFormat.monthDay(application.text("terminated_at")))
                               : ("答复截止", due.map { CareerDeckFormat.monthDay($0) })])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(oc ? "电话里说的" : "这份 Offer")
    }

    private func salary(_ text: String, note: String?) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(text).font(V3.serif(44)).foregroundStyle(JS.ink).lineLimit(1).minimumScaleFactor(0.6).frame(minHeight: 56)
            if let note { Text(note).font(V3.sans(13)).foregroundStyle(JS.sub).lineLimit(1).fixedSize() }
        }
    }

    private func rows(_ items: [(String, String?)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .leading), GridItem(.flexible(), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0).font(V3.sans(12.5)).foregroundStyle(JS.sub)
                    Text(item.1 ?? "没填").font(V3.sans(16, weight: .medium)).foregroundStyle(JS.ink).lineLimit(1).truncationMode(.tail)
                }
            }
        }.padding(.top, 10)
    }
}

// MARK: - 全程时间线（各分区底部；07.08 / 07.09 回看过去的节点）

struct CareerJourneyTimeline: View {
    let timeline: CareerJourney.Timeline
    /// 正在回看的站点。
    let picked: String?
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(timeline.head).font(V3.sans(13)).foregroundStyle(JS.sub).frame(height: 16)
            GeometryReader { geometry in
                let width = geometry.size.width
                let count = timeline.nodes.count
                let xs = (0...max(0, count)).map { index -> CGFloat in count > 1 ? width * CGFloat(index) / CGFloat(count - 1) : 0 }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(timeline.segments.enumerated()), id: \.offset) { index, segment in
                        segmentView(segment, from: xs[index], to: xs[index + 1])
                    }
                    if let today = timeline.today {
                        let left = xs[today.segment] + CGFloat(today.ratio) * (xs[today.segment + 1] - xs[today.segment])
                        Rectangle().fill(JS.ink).frame(width: 1, height: 30)
                            .overlay(alignment: .topLeading) {
                                Text("今天").font(V3.sans(12, weight: .medium)).foregroundStyle(JS.ink).fixedSize().offset(x: 6, y: -16)
                            }
                            .offset(x: left, y: 16).zIndex(3)
                    }
                    ForEach(Array(timeline.nodes.enumerated()), id: \.element.id) { index, node in
                        CareerJourneyNodeView(node: node, edge: index == 0 ? .first : index == count - 1 ? .last : .middle,
                                              picked: node.stationID != nil && node.stationID == picked, pick: pick)
                            .alignmentGuide(.leading) { d in
                                // 首个节点左缘在 -15，末个右缘在 width + 15，中间的居中对齐节点
                                index == 0 ? 15 : index == count - 1 ? d.width - width - 15 : d.width / 2 - xs[index]
                            }
                            .alignmentGuide(.top) { _ in -16 }
                            .zIndex(1)
                    }
                }
            }
            .frame(height: 128).padding(.top, 30)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("全程时间线")
    }

    @ViewBuilder private func segmentView(_ segment: CareerJourney.Segment, from: CGFloat, to: CGFloat) -> some View {
        ZStack(alignment: .top) {
            switch segment.style {
            case .future:
                Path { path in path.move(to: CGPoint(x: 0, y: 1)); path.addLine(to: CGPoint(x: to - from, y: 1)) }
                    .stroke(JS.track, style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
            case .current: Rectangle().fill(JS.blue)
            case .past: Rectangle().fill(JS.track)
            }
            if let days = segment.days {
                Text("\(days) 天").font(V3.sans(12, weight: .medium)).foregroundStyle(JS.mute).fixedSize().offset(y: -24)
            }
        }
        .frame(width: max(0, to - from), height: 2)
        .offset(x: from, y: 30)
        .allowsHitTesting(false)
    }
}

private struct CareerJourneyNodeView: View {
    enum Edge { case first, middle, last }
    let node: CareerJourney.Node
    let edge: Edge
    let picked: Bool
    let pick: (String) -> Void
    @State private var hover = false

    var body: some View {
        let clickable = node.stationID != nil && node.kind != .future
        let alignment: HorizontalAlignment = edge == .first ? .leading : edge == .last ? .trailing : .center
        let content = VStack(alignment: alignment, spacing: 5) {
            Text(node.label).font(V3.sans(14, weight: picked ? .semibold : node.kind == .future ? .regular : .medium))
                .foregroundStyle(labelColor).frame(height: 17)
            if let line = node.line { Text(line).font(V3.sans(12.5)).foregroundStyle(node.kind == .current ? JS.body : JS.sub).frame(height: 15) }
            if let note = node.note {
                HStack(spacing: 6) { Circle().fill(JS.orange).frame(width: 5, height: 5); Text(note) }
                    .font(V3.sans(12.5)).foregroundStyle(JS.body).frame(height: 15)
            }
        }
        .fixedSize()
        .padding(.top, 34).padding(.horizontal, 10).padding(.bottom, 8)
        .overlay(alignment: edge == .first ? .topLeading : edge == .last ? .topTrailing : .top) { dot.padding(.top, dotTop).padding(.horizontal, dotInset) }
        .contentShape(Rectangle())
        if clickable, let id = node.stationID {
            Button { pick(id) } label: { content }.buttonStyle(.plain)
                .onHover { hover = $0 }
                .help(picked || node.kind == .current ? "" : "查看\(node.label)")
                .accessibilityAddTraits(picked ? .isSelected : [])
                .accessibilityLabel([node.label, node.line, node.note].compactMap { $0 }.joined(separator: "，"))
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private var labelColor: Color {
        if picked { return JS.ink }
        switch node.kind {
        case .current: return JS.blue
        case .future: return JS.mute
        default: return JS.ink
        }
    }
    private var size: CGFloat { picked ? 12 : node.kind == .current ? 14 : 10 }
    private var dotTop: CGFloat { 10 - (size - 10) / 2 }
    private var dotInset: CGFloat { edge == .middle ? 0 : 10 - (size - 10) / 2 }

    @ViewBuilder private var dot: some View {
        if picked {
            Circle().fill(JS.ink).frame(width: 12, height: 12).background(Circle().fill(JS.ink.opacity(0.12)).padding(-5))
        } else {
            switch node.kind {
            case .current:
                Circle().fill(.white).overlay(Circle().stroke(JS.blue, lineWidth: 2)).frame(width: 14, height: 14)
                    .background(Circle().fill(JS.blue.opacity(hover ? 0.12 : 0)).padding(-4))
            case .future:
                Circle().fill(.white).overlay(Circle().stroke(JS.check, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))).frame(width: 10, height: 10)
            default:
                Circle().fill(JS.ink).frame(width: 10, height: 10).background(Circle().fill(JS.ink.opacity(hover ? 0.1 : 0)).padding(-4))
            }
        }
    }
}
