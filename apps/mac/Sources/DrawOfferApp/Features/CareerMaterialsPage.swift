import DrawOfferCore
import SwiftUI

/// Web `progress/MaterialsPage.tsx`：资料整页。顶部按轮次切换，一次只看一轮：
/// 上面是这一轮的成果（面试记录 + AI 复盘，笔试是笔试题，投递是简历和岗位 JD），下面是资料缩略图，最后一格添加。
/// 文件添加沿用原生「添加记录」弹窗（上传、资料库、粘贴），不做 Web 页底的拖放待处理栏。
struct CareerMaterialsPage: View {
    let application: JSONValue
    let deck: CareerDeck
    let details: [String: JSONValue]
    let initialSessionID: String?
    let splitting: Set<String>
    let back: () -> Void
    let openRecord: (String, CareerRecordPage.Mode) -> Void
    let openReview: (JSONValue) -> Void
    let generateReview: (JSONValue) -> Void
    let add: (JSONValue) -> Void
    let addFromLibrary: (JSONValue) -> Void
    let openResume: () -> Void
    let openJob: () -> Void
    @State private var selected: String?
    @State private var writtenOpen = false

    private var rounds: [CareerStation] {
        deck.stations.reversed().filter { $0.kind == .apply || ($0.session.map { $0.text("status") != "cancelled" } ?? false) }
    }

    var body: some View {
        let rounds = self.rounds
        let fallback = rounds.first { $0.current && $0.session != nil } ?? rounds.first { $0.session != nil } ?? rounds.first
        let station = selected.flatMap { key in rounds.first { $0.id == key } } ?? initialSessionID.flatMap { id in rounds.first { $0.session?.text("id") == id } } ?? fallback
        GeometryReader { geometry in
            let gutter = V3Page<EmptyView>.gutter(card: geometry.size.width)
            let width = min(920, max(0, geometry.size.width - gutter * 2))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: back) {
                        HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text("求职进度") }.font(V3.sans(14)).foregroundStyle(V3.fnt).frame(height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("返回求职进度").padding(.bottom, 12)
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text([application.text("company_name_snapshot"), application.text("job_title_snapshot")].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(V3.sans(13, weight: .medium)).foregroundStyle(PD.body).lineLimit(1).frame(height: 20)
                            Text("资料").font(V3.serif(30)).frame(height: 40)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        let target = station?.session ?? rounds.compactMap(\.session).first
                        Button { if let target { add(target) } } label: { HStack(spacing: 6) { Image(systemName: "square.and.arrow.up").font(.system(size: 12)); Text("上传资料") } }
                            .buttonStyle(PDButtonStyle(kind: .primary)).disabled(target == nil)
                    }
                    if !rounds.isEmpty { tabs(rounds, on: station?.id) }
                    if let station { panel(station) }
                    else { Text("这条投递还没有记录，记下投递后资料会按轮次放在这里。").font(V3.sans(13)).foregroundStyle(PD.mute).padding(.top, 28) }
                }
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, max(gutter, (geometry.size.width - width) / 2)).padding(.top, 52).padding(.bottom, 120)
            }
        }
        .foregroundStyle(PD.ink)
    }

    private func tabs(_ rounds: [CareerStation], on: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(rounds) { item in
                    let count = item.session.map { details[$0.text("id")]?["assets"]?.items.count ?? 0 }
                        ?? ((application.text("resume_id").isEmpty ? 0 : 1) + (application.text("job_description_id").isEmpty ? 0 : 1))
                    let selected = item.id == on
                    Button { self.selected = item.id; writtenOpen = false } label: {
                        HStack(spacing: 8) {
                            if item.current { Circle().fill(PD.blue).frame(width: 6, height: 6).accessibilityLabel("现在") }
                            Text(item.short).font(V3.sans(13.5, weight: .medium)).foregroundStyle(selected ? PD.ink : PD.body)
                            Text(CareerDeckFormat.monthDay(CareerApplication.date(item.session?.text("start_at") ?? "") ?? item.start)).font(.system(size: 12)).foregroundStyle(PD.mute)
                            Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? PD.blueText : PD.mute)
                        }
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(selected ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1.5, y: 1)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(4)
        }
        .background(Color(hex: 0xF5F5F2), in: RoundedRectangle(cornerRadius: 14))
        .fixedSize(horizontal: true, vertical: false)
        .padding(.top, 28)
        .accessibilityElement(children: .contain).accessibilityLabel("轮次")
    }

    // MARK: 这一轮

    private struct Outcome: Identifiable {
        let id: String
        let icon: String
        let tone: String
        let title: String
        var number: (String, String)?
        var state: (String, Bool)?
        var body: String?
        var meta: String?
        var actions: [(String, Bool, () -> Void)] = []
        var wide = false
    }

    @ViewBuilder private func panel(_ station: CareerStation) -> some View {
        let detail = station.session.flatMap { details[$0.text("id")] }
        if station.session != nil && detail == nil {
            Text("正在读取这一轮的资料…").font(V3.sans(13)).foregroundStyle(PD.mute).padding(.top, 28)
        } else {
            let (hint, outcomes) = self.outcomes(station, detail: detail)
            section("这一轮的成果", hint)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(outcomes) { item in
                    outcomeCard(item)
                    if item.wide { Color.clear.frame(height: 0) }
                }
            }
            if station.kind == .written && writtenOpen, let detail { written(detail) }
            if let session = station.session, let detail {
                let assets = detail["assets"]?.items ?? []
                // Mac 不做拖放待处理栏，说明里不写「拖文件到这里」
                section("资料", assets.isEmpty ? "还没有" : "\(assets.count) 份", link: ("从资料库选", { addFromLibrary(session) }))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), alignment: .leading, spacing: 16) {
                    ForEach(assets, id: \.self) { tile($0, detail: detail) }
                    Button { add(session) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 16))
                            Text("添加资料").font(V3.sans(13, weight: .medium))
                            Text(station.kind == .written ? "题目、截图、做题笔记都行" : "录音、笔记、截图都行").font(V3.sans(11.5)).foregroundStyle(PD.mute)
                        }
                        .foregroundStyle(PD.body).frame(maxWidth: .infinity, minHeight: 182)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xD6D6D0), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
            } else {
                Text("其他资料可以放进后面的笔试或面试。").font(V3.sans(13)).foregroundStyle(PD.mute).padding(.top, 28)
            }
        }
    }

    private func section(_ title: String, _ hint: String, link: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(V3.sans(15, weight: .medium))
            Text(hint).font(V3.sans(12.5)).foregroundStyle(PD.mute)
            if let link {
                Spacer()
                Button(link.0, action: link.1).buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(PD.ink)
            }
        }.frame(height: 23).padding(.top, 32).padding(.bottom, 12)
    }

    private func outcomeCard(_ item: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 14))
                    .foregroundStyle(item.tone == "blue" ? PD.blueText : item.tone == "purple" ? Color(hex: 0x7C5CD6) : PD.body)
                    .frame(width: 32, height: 32)
                    .background(item.tone == "blue" ? PD.tint : item.tone == "purple" ? Color(hex: 0xF2EEFD) : Color(hex: 0xF5F5F2), in: RoundedRectangle(cornerRadius: 10))
                Text(item.title).font(V3.sans(14, weight: .medium))
                Spacer(minLength: 0)
                ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.0, action: action.2).buttonStyle(.plain)
                        .font(V3.sans(14)).foregroundStyle(PD.ink).padding(.horizontal, 14).frame(height: 30)
                        .background(action.1 ? Color(hex: 0xEFEFEC) : .white, in: Capsule())
                        .overlay(Capsule().stroke(action.1 ? .clear : Color(hex: 0xE7E5DF)))
                }
            }.frame(minHeight: 32)
            if let number = item.number {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number.0).font(.system(size: 34, weight: .medium)).kerning(-0.68)
                    Text(number.1).font(V3.sans(14)).foregroundStyle(PD.body)
                }.frame(height: 40).padding(.top, 18)
            }
            if let state = item.state { Text(state.0).font(V3.sans(17, weight: .medium)).foregroundStyle(state.1 ? PD.mute : PD.ink).lineLimit(1).frame(height: 26).padding(.top, 18) }
            if let body = item.body { Text(body).font(V3.sans(13.5)).foregroundStyle(PD.body).lineSpacing(5).fixedSize(horizontal: false, vertical: true).padding(.top, 14) }
            if let meta = item.meta { Text(meta).font(V3.sans(12)).foregroundStyle(PD.mute).frame(minHeight: 18).padding(.top, 6) }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xE7E5DF)))
        .gridCellColumns(item.wide ? 2 : 1)
        .accessibilityElement(children: .contain).accessibilityLabel(item.title)
    }

    private func outcomes(_ station: CareerStation, detail: JSONValue?) -> (String, [Outcome]) {
        if station.kind == .apply {
            let resume = !application.text("resume_id").isEmpty
            let applied = CareerApplication.date(application.text("applied_at").nonEmptyValue ?? application.text("created_at"))
            let channel = application.text("applied_channel")
            return ("投递时用的简历和岗位", [
                resume ? Outcome(id: "resume", icon: "doc.text", tone: "blue", title: "投递简历", state: (application.text("resume_title_snapshot").nonEmptyValue ?? "投递简历", false),
                                 meta: "\(CareerDeckFormat.monthDay(applied))\(channel.isEmpty ? " " : " · \(channel) ")投递时使用", actions: [("打开 ›", false, openResume)])
                    : Outcome(id: "resume", icon: "doc.text", tone: "plain", title: "投递简历", state: ("没有记录", true), meta: "记录投递时可以选一份简历"),
                application.text("job_description_id").isEmpty
                    ? Outcome(id: "job", icon: "briefcase", tone: "plain", title: "岗位 JD", state: ("原岗位资料已不可用", true))
                    : Outcome(id: "job", icon: "briefcase", tone: "plain", title: "岗位 JD", state: (application.text("job_title_snapshot"), false), meta: application.text("company_name_snapshot"), actions: [("查看 ›", false, openJob)]),
            ])
        }
        guard let summary = station.session, let detail else { return ("", []) }
        let sessionID = summary.text("id")
        let session = detail["session"] ?? summary
        if station.kind == .written {
            let questions = session["written_questions"]?.items ?? []
            let marked = questions.filter { !$0.text("correctness").isEmpty }.count
            return ("笔试题目和做题后的笔记", [questions.isEmpty
                ? Outcome(id: "written", icon: "list.bullet", tone: "purple", title: "笔试题", body: "还没有题目。上传题目文档或截图转成的 PDF，AI 读出题目后可以逐题标答对 / 答错。", actions: [("上传题目文档", true, { add(summary) })], wide: true)
                : Outcome(id: "written", icon: "list.bullet", tone: "purple", title: "笔试题", number: ("\(questions.count)", "道题"),
                          meta: marked > 0 ? "\(marked) 道标了答得怎么样" : "还没标答得怎么样，点开逐题标答对 / 答错", actions: [(writtenOpen ? "收起" : "查看题目 ›", false, { writtenOpen.toggle() })], wide: true)])
        }
        let questions = InterviewRecord.parse(session.text("questions_markdown"))
        let transcriptions = session["transcriptions"]?.items ?? []
        let converting = transcriptions.contains { ["queued", "running"].contains($0.text("status")) }
        let assets = detail["assets"]?.items ?? []
        let source = assets.first { asset in transcriptions.contains { $0.text("dataset_id") == asset.text("id") && $0.text("status") == "succeeded" && $0["pending_replace"]?.bool != true } }
        var record = Outcome(id: "record", icon: "text.alignleft", tone: "blue", title: "面试记录")
        if splitting.contains(sessionID) {
            record.state = ("正在拆成问题", false); record.meta = "一般 20–40 秒，可以先去做别的"; record.actions = [("查看进度 ›", false, { openRecord(sessionID, .record) })]
        } else if !questions.isEmpty {
            let answered = InterviewRecord.answered(questions)
            record.number = ("\(questions.count)", "道题")
            record.meta = [answered == questions.count ? "\(answered) 道都记了回答" : "\(answered) 道记了回答", source.map { "来自 " + $0.text("original_file_name") }].compactMap { $0 }.joined(separator: " · ")
            record.actions = [("重新粘贴", false, { openRecord(sessionID, .paste) }), ("查看 ›", false, { openRecord(sessionID, .record) })]
        } else if converting {
            record.state = ("录音转文字中", false); record.meta = "转好后自动整理成面试记录，这里会更新"
        } else {
            record.state = ("还没有", true); record.meta = "上传录音或回忆笔记会自动整理；也可以直接粘贴文字"; record.actions = [("粘贴文字", false, { openRecord(sessionID, .paste) })]
        }
        var review = Outcome(id: "review", icon: "sparkle", tone: "purple", title: "AI 复盘")
        if summary.text("review_status") == "generating" {
            review.body = "正在复盘，一般 1 分钟左右，好了这里会更新。"; review.actions = [("打开 ›", false, { openReview(summary) })]
        } else if summary.text("review_status") == "failed" {
            review.body = "这次没生成出来，可以再试一次。"; review.actions = [("再试一次", true, { generateReview(summary) })]
        } else if CareerDeck.hasReview(summary) {
            review.state = (headline(summary), false); review.meta = "点开看每道题的分析"; review.actions = [("查看 ›", false, { openReview(summary) })]
        } else if !questions.isEmpty {
            review.body = "用这一轮 \(questions.count) 道题的面试记录，逐题点评回答、标出薄弱的地方，并列出下一轮要准备的内容。"
            review.meta = "大约 1 分钟"; review.actions = [("生成复盘", true, { generateReview(summary) })]
        } else {
            review.body = "有了面试记录就能生成：逐题点评、标出薄弱的地方，并列出下一轮要准备的内容。"; review.meta = "先把这一轮的问题记进面试记录"
        }
        return ("录音和笔记整理出来的东西", [record, review])
    }

    private func headline(_ session: JSONValue) -> String {
        let report = session["review_report"] ?? .null
        let text = report["schema_version"]?.integer == 2 ? report.text("headline").nonEmptyValue ?? "每道题都答到了位"
            : report.text("summary").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? session.text("review_summary").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? "复盘已生成"
        return text.count > 22 ? String(text.prefix(22)) + "…" : text
    }

    // MARK: 资料缩略图

    private func tile(_ asset: JSONValue, detail: JSONValue) -> some View {
        let name = asset.text("original_file_name")
        let media = asset.text("asset_type") != "document"
        let ext = name.contains(".") ? String(name.split(separator: ".").last ?? "").uppercased() : ""
        let transcription = (detail["session"]?["transcriptions"]?.items ?? []).first { $0.text("dataset_id") == asset.text("id") }
        let status: (String, Color)? = !media ? nil
            : ["queued", "running"].contains(transcription?.text("status") ?? "") ? ("正在转文字", PD.blueText)
            : transcription?.text("status") == "failed" ? ("没能转成文字", Color(hex: 0xA35A12))
            : transcription?.text("status") == "succeeded" && transcription?["pending_replace"]?.bool == true ? ("已转好，还没替换记录", PD.mute)
            : transcription?.text("status") == "succeeded" ? ("已转写", PD.mute) : nil
        let kind = media ? (asset.text("asset_type") == "video" ? "视频" : "录音") : ext == "MD" || ext == "TXT" ? "笔记" : "文档"
        let ms = asset["duration_ms"]?.integer ?? 0
        let size = media ? (ms > 0 ? String(format: "%02d:%02d", ms / 1000 / 60, ms / 1000 % 60) : nil)
            : ByteCountFormatter.string(fromByteCount: Int64(asset["file_size"]?.integer ?? 0), countStyle: .file)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if media { wave(asset.text("id")).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xFDF2E9)) }
                else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(0..<6, id: \.self) { index in Capsule().fill(Color(hex: 0xDCDCD8)).frame(height: 4).frame(maxWidth: index % 3 == 2 ? 40 : .infinity, alignment: .leading) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.top, 14)
                    .frame(width: 80, height: 103).background(.white, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).background(Color(hex: 0xF7F7F5))
                }
                if let label = media ? size : ext.nonEmptyValue {
                    Text(label).font(.system(size: media ? 12 : 10, weight: .semibold)).foregroundStyle(media ? Color(hex: 0xA35A12) : PD.mute).padding(.trailing, 12).padding(.bottom, 10)
                }
            }.frame(height: 120).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(V3.sans(13, weight: .medium)).lineLimit(1).frame(height: 20).help(name)
                (Text([kind, size].compactMap { $0 }.joined(separator: " · ")) + Text(status.map { " · " + $0.0 } ?? "").foregroundColor(status?.1 ?? PD.mute))
                    .font(V3.sans(11.5)).foregroundStyle(PD.mute).frame(minHeight: 17, alignment: .leading)
            }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        }
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xE7E5DF)))
    }

    /// 录音缩略图：按文件 ID 生成稳定的装饰波形，不代表真实音量。
    private func wave(_ seed: String) -> some View {
        var value = seed.unicodeScalars.reduce(17) { $0 + Int($1.value) }
        let bars: [CGFloat] = (0..<36).map { index in
            value = (value * 9301 + 49297) % 233280
            let envelope = 0.4 + 0.6 * sin(Double(index) / 36 * .pi)
            return CGFloat((8 + envelope * Double(value) / 233280 * 44).rounded())
        }
        return HStack(spacing: 2.5) { ForEach(Array(bars.enumerated()), id: \.offset) { Capsule().fill(Color(hex: 0xE8853D)).frame(width: 2.5, height: $0.element) } }
            .frame(height: 56).padding(.horizontal, 16).accessibilityHidden(true)
    }

    // MARK: 笔试题

    private func written(_ detail: JSONValue) -> some View {
        let questions = detail["session"]?["written_questions"]?.items ?? []
        let marked = questions.filter { !$0.text("correctness").isEmpty }.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("笔试题").font(V3.serif(17))
                Text("\(questions.count) 道题 · \(marked) 道标了答得怎么样").font(V3.sans(11, weight: .medium)).foregroundStyle(PD.blueText).padding(.horizontal, 8).frame(height: 20).background(PD.tint, in: RoundedRectangle(cornerRadius: 6))
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Rectangle().fill(Color(hex: 0xECEAE4)).frame(height: 1)
            if questions.isEmpty {
                Text("还没有题目。上传题目文档后可以逐题查看。").font(V3.sans(12.5)).foregroundStyle(PD.mute).padding(20)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, item in
                        let mark = ["correct": "答对", "wrong": "答错", "unsure": "不确定"][item.text("correctness")] ?? "先不标"
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.display("question_no")). \(item.text("question_text"))").font(V3.sans(13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text("我的答案：" + (item.text("answer").nonEmptyValue ?? "没记答案。") + " · " + mark).font(V3.sans(12.5)).foregroundStyle(PD.body)
                        }.padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF1F0EC)).frame(height: 1) }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xCDDCF5)))
        .shadow(color: Color(hex: 0x1D3666).opacity(0.06), radius: 10, y: 6)
        .padding(.top, 16)
    }
}
