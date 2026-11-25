import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 05.03 · 笔试题（Figma 07 页 82:44496；业务同 Web `MaterialsPage.WrittenPanel`）。
/// 页头同投递详情；中间左边是选中的这道题，右边写结果和改对错；最下面一排答题卡（错的橙圈、当前的蓝底）。
/// 「添加题目」打开 05.04。
struct CareerWrittenPage: View {
    let application: JSONValue
    let station: CareerStation
    let detail: JSONValue
    let api: any APIClient
    let backLabel: String
    let back: () -> Void
    let openMaterials: () -> Void
    /// 题目或对错变了，让上层重新读取。
    let changed: () -> Void
    @State private var marks: [String: JSONValue] = [:]
    @State private var index = 0
    @State private var adding = false
    @State private var busy = false
    @State private var notice: String?

    private var session: JSONValue { detail["session"] ?? .null }
    private var questions: [JSONValue] { (session["written_questions"]?.items ?? []).map { marks[$0.text("id")] ?? $0 } }

    var body: some View {
        let list = questions
        let current = list.isEmpty ? nil : list[min(index, list.count - 1)]
        CareerSubpageFrame { _ in
            VStack(alignment: .leading, spacing: 0) {
                CareerSubpageHead(backLabel: backLabel, back: back, title: title(list), menu: [CareerSubpageMenuItem(title: "查看这一轮的资料", action: openMaterials)]) {
                    // 有题时整页没有黑按钮；还没有题时「添加题目」是唯一的主操作
                    Button("添加题目") { adding = true }.buttonStyle(PDButtonStyle(kind: list.isEmpty ? .primary : .normal))
                }
                if let current {
                    Spacer(minLength: 40)
                    HStack(alignment: .top, spacing: 48) {
                        questionView(current, list: list).frame(maxWidth: 560, alignment: .leading)
                        Spacer(minLength: 0)
                        resultView(current).frame(width: 380, alignment: .leading)
                    }
                    Spacer(minLength: 40)
                    answerCard(list).padding(.bottom, 48)
                } else {
                    Text("\(station.short)还没有题目。题目截图、文档或直接粘贴文字都可以，作答和判分写在题目里会一起识别。")
                        .font(V3.sans(13)).foregroundStyle(PD.mute).padding(.top, 48)
                    Spacer()
                }
            }
        }
        .foregroundStyle(V3.txt)
        .overlay(alignment: .top) { TextNoticeToast(text: $notice, kind: { $0.hasPrefix("已") ? .done : $0.contains("已刷新") ? .attention : .failed }) }
        .onChange(of: session["lock_version"]?.integer ?? 0) { _, _ in marks = [:] }
        .onKeyPress(.leftArrow) { if index > 0 { index -= 1 }; return .handled }
        .onKeyPress(.rightArrow) { if index < list.count - 1 { index += 1 }; return .handled }
        .centeredSheet(isPresented: $adding) {
            CareerWrittenAddSheet(detail: detail, api: api, close: { adding = false },
                                  saved: { count in adding = false; index = 0; notice = "已导入 \(count) 道题。"; changed() })
        }
    }

    private func title(_ list: [JSONValue]) -> String {
        if list.isEmpty { return "\(station.short)还没有题目。" }
        let marked = list.filter { !$0.text("correctness").isEmpty }.count
        let correct = list.filter { $0.text("correctness") == "correct" }.count
        return marked > 0 ? "\(station.short)答对 \(correct) / \(list.count)。" : "\(station.short)有 \(list.count) 道题。"
    }

    // MARK: 选中的这道题

    private func questionView(_ item: JSONValue, list: [JSONValue]) -> some View {
        let parsed = CareerWrittenOptions.split(item.text("question_text"))
        let picked = CareerWrittenOptions.letters(item.text("answer"))
        let position = min(index, list.count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            Text("第 \(item.display("question_no").nonEmptyValue ?? String(position + 1)) 题" + (parsed.options.isEmpty ? "" : picked.count > 1 ? " · 多选" : ""))
                .font(V3.sans(12.5)).foregroundStyle(PD.mute).frame(height: 16)
            Text(parsed.stem.nonEmptyValue ?? "（没记下题目）").font(V3.sans(19, weight: .medium)).foregroundStyle(V3.txt).lineHeight(19, 28)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 14)
            if parsed.options.isEmpty {
                // 不是选择题：直接写我的答案
                Text("我的答案").font(V3.sans(12.5)).foregroundStyle(PD.mute).padding(.top, 26)
                Text(item.text("answer").nonEmptyValue ?? "没记答案。").font(V3.sans(15)).foregroundStyle(item.text("answer").isEmpty ? PD.mute : PD.body)
                    .lineHeight(15, 26).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(parsed.options, id: \.letter) { option in
                        let on = picked.contains(option.letter)
                        HStack(spacing: 14) {
                            Text(option.letter).font(.system(size: 11, weight: .medium)).foregroundStyle(on ? .white : PD.mute)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(on ? PD.blue : .white))
                                .overlay(Circle().stroke(on ? PD.blue : V3.cl))
                            Text(option.text).font(V3.sans(15, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : PD.body)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            if on { Text("你选了").font(V3.sans(12)).foregroundStyle(PD.mute) }
                        }.frame(minHeight: 44)
                    }
                }.padding(.top, 18)
            }
            HStack(spacing: 28) {
                if position > 0 {
                    CareerJourneyTextButton(title: "‹ 第 \(position) 题", size: 13, color: PD.mute) { index = position - 1 }
                }
                if position < list.count - 1 {
                    Button { index = position + 1 } label: { Text("第 \(position + 2) 题 ›").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                }
            }.frame(height: 20).padding(.top, 28)
        }
    }

    // MARK: 结果

    private func resultView(_ item: JSONValue) -> some View {
        let mark = item.text("correctness")
        let (headline, color): (String, Color) = switch mark {
        case "wrong": ("答错。", PD.orangeText)
        case "correct": ("答对。", V3.txt)
        case "unsure": ("不确定。", V3.txt)
        default: ("还没标。", PD.mute)
        }
        let options: [(String, String?)] = switch mark {
        case "wrong": [("改为答对", "correct"), ("改为不确定", "unsure")]
        case "correct": [("改为答错", "wrong"), ("改为不确定", "unsure")]
        case "unsure": [("改为答对", "correct"), ("改为答错", "wrong")]
        default: [("标为答对", "correct"), ("标为答错", "wrong"), ("不确定", "unsure")]
        }
        return VStack(alignment: .leading, spacing: 0) {
            // 稿 05.03：「结果」13/500 #6c6c65，结论衬线 24（框高 34，距上 13），下面一行 13；整列比题号低 38
            Text("结果").font(V3.sans(13, weight: .medium)).foregroundStyle(Color(hex: 0x6C6C65)).frame(height: 16)
            Text(headline).font(V3.serif(24)).foregroundStyle(color).frame(height: 34).padding(.top, 13)
            HStack(spacing: 14) {
                if item.text("mark_source") == "recognized" { Text("导入时识别").font(V3.sans(13)).foregroundStyle(Color(hex: 0x6C6C65)) }
                ForEach(options, id: \.0) { option in
                    CareerJourneyTextButton(title: option.0, size: 13, color: PD.body) { Task { await setMark(item, option.1) } }.disabled(busy)
                }
                if !mark.isEmpty { CareerJourneyTextButton(title: "清除", size: 13, color: PD.mute) { Task { await setMark(item, nil) } }.disabled(busy) }
            }.frame(height: 16).padding(.top, 5)
        }
        .padding(.top, 38)
    }

    // MARK: 答题卡

    private func answerCard(_ list: [JSONValue]) -> some View {
        let wrong = list.filter { $0.text("correctness") == "wrong" }.count
        return HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("共 \(list.count) 题").font(V3.sans(12.5)).foregroundStyle(PD.mute).frame(height: 15)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.offset) { position, item in
                        let on = position == min(index, list.count - 1)
                        let miss = item.text("correctness") == "wrong"
                        Button { index = position } label: {
                            Text("\(position + 1)").font(.system(size: 12, weight: on ? .semibold : .regular)).monospacedDigit()
                                .foregroundStyle(on ? .white : miss ? PD.orangeText : V3.txt)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(on ? PD.blue : .white))
                                .overlay(Circle().stroke(on ? PD.blue : miss ? PD.orangeText : V3.cl, lineWidth: miss && !on ? 1.5 : 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(position + 1) 题" + (miss ? "，答错" : ""))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if wrong > 0 {
                HStack(spacing: 8) {
                    Circle().stroke(PD.orangeText, lineWidth: 1.5).frame(width: 9, height: 9)
                    Text("答错 \(wrong) 道").font(V3.sans(12.5)).foregroundStyle(PD.body)
                }.frame(height: 32)
            }
        }
    }

    // MARK: 行为

    /// 逐题标对错（Web `markWrittenQuestion`）：整体覆盖这道题的作答和对错，作答保持原样。
    private func setMark(_ item: JSONValue, _ value: String?) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/written-questions/\(item.text("id"))", method: "PATCH", query: [:],
                                                     body: .object(["answer": item.text("answer").isEmpty ? .null : .string(item.text("answer")),
                                                                    "correctness": value.map { .string($0) } ?? .null,
                                                                    "lock_version": item["lock_version"] ?? .number(1)]))
            if let updated = result["question"] { marks[item.text("id")] = updated }
            notice = nil
        } catch {
            if case APIError.server(409, _) = error { notice = "这道题已在别处修改，已刷新为最新内容。"; changed() }
            else { notice = CareerErrors.message(error) }
        }
    }
}

extension PD {
    /// 笔试答错、答题卡错题圈（稿 #D9822B 上的文字）。
    static let orangeText = Color(hex: 0xD9822B)
}

/// 选择题拆成题干和选项：识别「A. xxx」「B、xxx」这类行，一行里并排写的几个选项也能拆开。
enum CareerWrittenOptions {
    struct Option { let letter: String; let text: String }
    private static let marker = try! NSRegularExpression(pattern: #"(?:^|\s)([A-H])\s*[\.．、:：\)）]\s*"#)

    static func split(_ text: String) -> (stem: String, options: [Option]) {
        var stem: [String] = []
        var options: [Option] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            let matches = marker.matches(in: line, range: range)
            if let first = matches.first, first.range.location == 0 {
                for (position, match) in matches.enumerated() {
                    guard let letter = Range(match.range(at: 1), in: line), let start = Range(match.range, in: line)?.upperBound else { continue }
                    let end = position + 1 < matches.count ? (Range(matches[position + 1].range, in: line)?.lowerBound ?? line.endIndex) : line.endIndex
                    options.append(Option(letter: String(line[letter]), text: String(line[start..<end]).trimmingCharacters(in: .whitespaces)))
                }
            } else if !options.isEmpty, !line.isEmpty, let last = options.popLast() {
                options.append(Option(letter: last.letter, text: last.text + " " + line))
            } else if !line.isEmpty { stem.append(line) }
        }
        // 只有一个「选项」多半是题干里的普通编号，不当选择题
        return options.count < 2 ? (text.trimmingCharacters(in: .whitespacesAndNewlines), []) : (stem.joined(separator: "\n"), options)
    }

    /// 作答是「B」「AB」「A、B」这类字母时，取出选了哪几项；不是时返回空。
    static func letters(_ answer: String) -> Set<String> {
        let value = answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !value.isEmpty, value.range(of: #"^[A-H](?:[\s,，、/]*[A-H])*$"#, options: .regularExpression) != nil else { return [] }
        return Set(value.compactMap { ("A"..."H").contains(String($0)) ? String($0) : nil })
    }
}

/// 05.04 · 添加笔试题（Figma 07 页 82:44497；业务同 Web `WrittenImportDialog`）：
/// 三种来源是三张并排的卡，选中的描黑边；正文只留输入框，作答和判分写在题目里会一起识别。
/// 识别后在同一块里预览，确认再导入（整体替换这一轮的题目）。
struct CareerWrittenAddSheet: View {
    enum Source: String, CaseIterable { case text, images, dataset }
    let detail: JSONValue
    let api: any APIClient
    let close: () -> Void
    let saved: (Int) -> Void
    @State private var source: Source = .text
    @State private var text = ""
    @State private var images: [URL] = []
    @State private var datasets: [JSONValue]?
    @State private var datasetID = ""
    @State private var preview: JSONValue?
    @State private var busy: String?
    @State private var error: String?
    private var session: JSONValue { detail["session"] ?? .null }
    private var existing: Int { session["written_questions"]?.items.count ?? 0 }
    private var ready: Bool { source == .text ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : source == .images ? !images.isEmpty : !datasetID.isEmpty }
    private var recognized: [JSONValue] { preview?["questions"]?.items ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("添加笔试题").font(V3.serif(22)).foregroundStyle(V3.txt).frame(height: 32)
            HStack(spacing: 12) {
                card(.text, title: "粘贴文字", sub: "带不带题号都行")
                card(.images, title: "上传截图", sub: "最多 5 张")
                card(.dataset, title: "资料库文档", sub: "选一份已上传的")
            }.padding(.top, 20)
            Group {
                if preview != nil { previewBody } else { input }
            }
            .frame(height: 196).frame(maxWidth: .infinity)
            .background(Color(hex: 0xF7F7F5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(PD.red).padding(.top, 10) }
            HStack(spacing: 16) {
                if existing > 0 {
                    HStack(spacing: 8) {
                        Circle().fill(PD.orangeText).frame(width: 5, height: 5)
                        Text("会替换现在的 \(existing) 道题").font(V3.sans(12.5)).foregroundStyle(PD.body)
                    }
                }
                Spacer()
                CareerJourneyTextButton(title: "取消", color: PD.body, action: close).disabled(busy != nil)
                if preview != nil {
                    Button(busy == "save" ? "正在导入…" : "导入 \(recognized.count) 题") { Task { await save() } }
                        .buttonStyle(PDButtonStyle(kind: .primary)).disabled(busy != nil || recognized.isEmpty).keyboardShortcut(.defaultAction)
                } else {
                    Button(busy == "extract" ? "正在识别…" : "识别题目") { Task { await extract() } }
                        .buttonStyle(PDButtonStyle(kind: .primary)).disabled(!ready || busy != nil)
                }
            }.padding(.top, 24)
        }
        .padding(28).frame(width: 600)
        .interactiveDismissDisabled(busy != nil)
    }

    private func card(_ item: Source, title: String, sub: String) -> some View {
        let on = source == item
        return Button { source = item; preview = nil; error = nil } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                Text(sub).font(V3.sans(12)).foregroundStyle(PD.mute)
            }
            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? V3.txt : V3.cl, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(busy != nil)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var input: some View {
        switch source {
        case .text:
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { text }, set: { text = String($0.prefix(20_000)); preview = nil }))
                    .font(V3.sans(13.5)).lineSpacing(7).scrollContentBackground(.hidden).padding(.horizontal, 13).padding(.vertical, 16)
                    .accessibilityLabel("题目内容")
                if text.isEmpty {
                    Text("1. TCP 三次握手中，服务端第二次握手发出的是？\nA. SYN    B. SYN + ACK    C. ACK    D. FIN\n我的答案：B\n\n2. 下面哪些是 Redis 支持的持久化方式？……")
                        .font(V3.sans(13.5)).lineSpacing(7).foregroundStyle(PD.mute).padding(.horizontal, 18).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
        case .images:
            Button { pickImages() } label: {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 18)).foregroundStyle(PD.mute)
                    Text(images.isEmpty ? "选择截图，或把截图拖到这里" : images.map(\.lastPathComponent).joined(separator: "、"))
                        .font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(2).multilineTextAlignment(.center)
                    Text(images.isEmpty ? "PNG、JPG 或 WebP，按顺序识别，每张不超过 5MB；截图识别后不保存" : "再点一次可以重新选择")
                        .font(V3.sans(12)).foregroundStyle(PD.mute)
                }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(busy != nil)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                CareerDrop.files(providers) { urls in accept(images + urls) }
                return true
            }
        case .dataset:
            if let datasets {
                if datasets.isEmpty {
                    Text("资料库还没有解析好的 PDF 或 Word 文档。").font(V3.sans(13)).foregroundStyle(PD.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(datasets, id: \.self) { item in
                                let on = datasetID == item.text("id")
                                Button { datasetID = item.text("id"); preview = nil } label: {
                                    HStack(spacing: 10) {
                                        Circle().stroke(on ? V3.txt : PD.mute.opacity(0.6), lineWidth: on ? 4 : 1).frame(width: 13, height: 13)
                                        Text(item.text("file_name")).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }.frame(height: 32).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 18).padding(.vertical, 10)
                    }
                }
            } else {
                Text("正在读取资料库…").font(V3.sans(13)).foregroundStyle(PD.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        do {
                            let result = try await api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil)
                            datasets = (result["datasets"]?.items ?? result["items"]?.items ?? [])
                                .filter { ($0.text("asset_kind").isEmpty || $0.text("asset_kind") == "document") && $0.text("parse_status") == "succeeded" }
                        } catch { datasets = []; self.error = CareerErrors.message(error) }
                    }
            }
        }
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("识别到 \(recognized.count) 题").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt)
                Spacer()
                CareerJourneyTextButton(title: "返回修改", size: 12.5, color: PD.body) { preview = nil }.disabled(busy != nil)
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recognized.enumerated()), id: \.offset) { position, item in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(format: "%02d", item["no"]?.integer ?? position + 1)).font(.system(size: 11, weight: .medium)).foregroundStyle(PD.mute)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text("text")).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(2)
                                let extra = [item.text("answer").nonEmptyValue.map { "作答：\($0)" }, ["correct": "对", "wrong": "错"][item.text("result")]].compactMap { $0 }
                                if !extra.isEmpty { Text(extra.joined(separator: " · ")).font(V3.sans(12)).foregroundStyle(item.text("result") == "wrong" ? PD.orangeText : PD.mute) }
                            }
                        }.padding(.vertical, 6)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, UTType(filenameExtension: "webp") ?? .image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        accept(panel.urls)
    }

    private func accept(_ picked: [URL]) {
        let usable = picked.filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
        guard !usable.isEmpty else { error = "截图无法识别，请上传 png、jpg 或 webp 图片。"; return }
        if usable.count > CareerUpload.maxImages { error = "一次最多上传 5 张截图。"; return }
        if usable.contains(where: { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) > CareerUpload.maxImageBytes }) { error = "每张截图不能超过 5MB。"; return }
        error = nil; preview = nil; images = usable
    }

    private func extract() async {
        busy = "extract"; error = nil; defer { busy = nil }
        do {
            var body: [String: JSONValue] = ["source": .string(source.rawValue)]
            switch source {
            case .text: body["text"] = .string(text)
            case .dataset: body["dataset_id"] = .string(datasetID)
            case .images:
                body["images"] = .array(try images.map { url in
                    let type = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"][url.pathExtension.lowercased()] ?? "application/octet-stream"
                    return JSONValue.object(["base64": .string(try Data(contentsOf: url).base64EncodedString()), "content_type": .string(type)])
                })
            }
            preview = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/written-questions:extract", method: "POST", query: [:], body: .object(body))
        } catch { self.error = Self.message(error) }
    }

    /// 确认导入：带识别出的作答与判分整体替换（`PUT .../written-questions`）。
    /// 服务端还没对桌面开放这条接口时，退回只保存题目文字（`questions_markdown`），作答和对错之后逐题补。
    private func save() async {
        guard let preview else { return }
        busy = "save"; error = nil; defer { busy = nil }
        let id = session.text("id")
        let lock = session["lock_version"] ?? .number(1)
        let items: [JSONValue] = recognized.map { item in
            .object(["text": .string(item.text("text")), "answer": item.text("answer").isEmpty ? .null : .string(item.text("answer")),
                     "result": item.text("result").isEmpty ? .null : .string(item.text("result"))])
        }
        do {
            do {
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(id)/written-questions", method: "PUT", query: [:], body: .object(["questions": .array(items), "base_lock_version": lock]))
            } catch APIError.server(403, _) {
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "PUT", query: [:], body: .object(["questions_markdown": preview["markdown"] ?? .null, "base_lock_version": lock]))
            }
            saved(recognized.count)
        } catch { self.error = Self.message(error) }
    }

    private static func message(_ error: Error) -> String {
        if case APIError.server(_, let code) = error, let text = [
            "INTERVIEW_QUESTIONS_NOT_FOUND": "没有识别到题目，请检查内容后重试。",
            "INTERVIEW_IMPORT_MODEL_NOT_CONFIGURED": "识别模型还没有配置，请联系管理员。",
            "INTERVIEW_IMPORT_TEXT_TOO_LONG": "内容超过 20,000 字，请分批导入。",
            "INTERVIEW_IMPORT_IMAGE_TOO_LARGE": "每张截图不能超过 5MB。",
            "INTERVIEW_IMPORT_IMAGE_INVALID": "截图无法识别，请上传 png、jpg 或 webp 图片。",
            "INTERVIEW_IMPORT_IMAGE_COUNT": "一次最多上传 5 张截图。",
            "INTERVIEW_IMPORT_DATASET_NOT_READY": "这份文件还没有解析完成，请稍后再试。",
            "INTERVIEW_IMPORT_TIMEOUT": "识别超时，请稍后重试。",
        ][code] { return text }
        return CareerErrors.message(error)
    }
}

/// 拖进来的文件：从 NSItemProvider 取出本地文件地址。
enum CareerDrop {
    /// 每取到一个本地文件就回主线程交给 `handle`（一次一个）。
    static func files(_ providers: [NSItemProvider], _ handle: @escaping @MainActor @Sendable ([URL]) -> Void) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in handle([url]) }
            }
        }
    }
}
