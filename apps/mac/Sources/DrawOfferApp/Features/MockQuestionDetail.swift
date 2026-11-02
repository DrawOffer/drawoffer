import DrawOfferCore
import SwiftUI

/// 单题详情（Web `ReportV2.tsx` 的 QuestionDetail，Figma 09 · RP-2a / RP-2b）：左边逐轮问答（可回放录音、看 AI 修正、手动修改识别稿），
/// 右边这题在这场图上的位置、分数、面试官怎么批的、亮点与待改进、参考思路，以及重新评估。
struct MockQuestionDetail: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let rows: [MockReview.Row]
    let row: MockReview.Row
    let open: (String?) -> Void
    let home: () -> Void
    let focus: (String) -> Void
    let updated: (JSONValue) -> Void
    let toast: ((title: String, message: String, error: Bool)) -> Void

    private static let maxReEvaluate = 3
    @State private var editing = false
    @State private var raw = false
    @State private var drafts: [String: String] = [:]
    @State private var busy: String?
    @State private var context = MockSessionContext()
    @State private var player = InterviewerVoice()
    @State private var playing: String?

    private var evaluation: JSONValue? { row.evaluation.flatMap { $0 == .null ? nil : $0 } }
    private var target: Double { MockMap.diffLevel[detail.text("difficulty")] ?? 3 }
    private var reached: Double { guard let evaluation, evaluation["skipped"]?.bool != true else { return 0 }; return max(0, min(5, evaluation["achieved_depth"]?.numberValue ?? 0)) }
    private var probed: Double { max(row.round.to, evaluation?["probed_depth"]?.numberValue ?? 0) }
    private var root: JSONValue { row.round.main }
    private var remaining: Int { max(0, Self.maxReEvaluate - (root["re_evaluate_count"]?.integer ?? 0)) }
    private var editable: [JSONValue] { row.round.turns.filter { $0.text("answer_source") == "voice" && $0.text("answer_status") == "answered" } }
    private var corrected: Int { row.round.turns.reduce(0) { $0 + ($1.text("transcript_state") == "corrected" ? $1["correction"]?["changes"]?.items.count ?? 0 : 0) } }

    var body: some View {
        let index = rows.firstIndex { $0.no == row.no } ?? 0
        let prev = rows[safe: index - 1], next = rows[safe: index + 1]
        GeometryReader { geometry in
            // `.mi2-qd`：最宽 page-max + 112，左右 56 的留白；左栏 484、右栏 496、中间 60
            let width = min(geometry.size.width, V3Page<EmptyView>.maxWidth(card: geometry.size.width) + 112) - 112
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    head
                    HStack(alignment: .top, spacing: 60) {
                        left(prev: prev).frame(width: min(484, (width - 60) * 484 / 980), alignment: .leading)
                        right(index: index, next: next).frame(width: min(496, (width - 60) * 496 / 980), alignment: .leading)
                        Spacer(minLength: 0)
                    }.padding(.top, 28)
                }
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 56).padding(.top, 52).padding(.bottom, 48)
                .frame(width: geometry.size.width)
            }
        }
        .background(.white).foregroundStyle(RR.ink)
        .task(id: detail.display("id")) { await context.load(detail, api: session.api) }
        .onDisappear { player.stop() }
    }

    // MARK: 头部

    private var head: some View {
        let skipped = evaluation?["skipped"]?.bool == true
        let tag = reached == 0 ? (skipped ? "跳过了" : "追问到「\(MockMap.levelName(max(1, probed)))」没答上")
            : probed > reached ? "追问到「\(MockMap.levelName(probed))」 · 答到「\(MockMap.levelName(reached))」" : "答到「\(MockMap.levelName(reached))」"
        let voice = row.round.turns.contains { $0.text("answer_source") == "voice" }
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: home) { HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text("模拟面试") }.contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("返回模拟面试")
                    Text("/").accessibilityHidden(true)
                    Button("评估报告") { open(nil) }.buttonStyle(.plain)
                    Text("/").accessibilityHidden(true)
                    Text("第 \(row.no) 题")
                }.font(V3.sans(16)).foregroundStyle(V3.fnt).frame(height: 20)
                Text(verbatim: "Q\(row.no)  \(row.round.topic)").font(V3.serif(26)).frame(height: 22).padding(.top, 12)
                HStack(spacing: 10) {
                    chip(tag, reached >= target ? .blue : .or)
                    chip("追问 \(row.round.turns.count - 1) 次", .grey)
                    if corrected > 0 { chip("AI 已修正 \(corrected) 处识别 · 已自动应用", .blue) }
                    if voice && corrected == 0 && detail.text("transcript_corrected_at").isEmpty {
                        Button(busy == "correct" ? "正在修正识别…" : "让 AI 修正识别") { Task { await correct() } }
                            .buttonStyle(.plain).font(V3.sans(11)).foregroundStyle(RR.blue).padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(RR.blue, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))).disabled(busy != nil)
                    }
                }.frame(height: 26).padding(.top, 8)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(rows, id: \.no) { item in
                    let on = item.no == row.no
                    Button { open(item.round.main.display("id")) } label: {
                        Text("Q\(item.no)").font(V3.sans(11.5)).foregroundStyle(on ? .white : RR.ink).frame(minWidth: 20).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(on ? RR.ink : .white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? RR.ink : MI.line))
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
            }.padding(.trailing, 56)
            Button { open(nil) } label: { Text("×").font(V3.sans(18)).foregroundStyle(RR.mute) }.buttonStyle(.plain).accessibilityLabel("回到报告").offset(y: -2)
        }
    }

    private enum ChipTone { case blue, or, grey }
    private func chip(_ text: String, _ tone: ChipTone) -> some View {
        let (fg, bg): (Color, Color) = tone == .blue ? (RR.blue, Color(hex: 0xEEF2FB)) : tone == .or ? (RR.or, Color(hex: 0xFBEFE2)) : (RR.sub, Color(hex: 0xEFEDE7))
        return Text(verbatim: text).font(V3.sans(11)).foregroundStyle(fg).frame(height: 22).padding(.horizontal, 7).padding(.vertical, 2).background(bg, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: 左栏：逐轮问答

    private func left(prev: MockReview.Row?) -> some View {
        let notProbed = (evaluation?["signals"]?.items ?? []).filter { $0.text("verdict") == "not_probed" }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(row.round.turns.enumerated()), id: \.offset) { position, turn in turnView(turn, position: position) }
            if let first = notProbed.first, probed < 5 {
                let level = min(5, probed + 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text("没问到 · 第 \(Int(level)) 层 · \(MockMap.levelName(level))").font(V3.sans(10.5)).foregroundStyle(MI.gry).frame(height: 22).padding(.horizontal, 7).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(MI.line))
                    line("面试官", "面试官原本想接着问：「\(first.text("signal"))」", blue: true, grey: true)
                }.turnBlock()
            }
            if editing {
                HStack(spacing: 10) {
                    Button(busy == "save" ? "正在保存…" : remaining > 0 ? "保存并重新评估" : "保存") { Task { await save() } }.buttonStyle(MockButtonStyle(kind: .dark)).disabled(busy != nil)
                    Button("取消") { editing = false; drafts = [:] }.buttonStyle(MockButtonStyle(kind: .link))
                }.padding(.top, 8)
                Text(remaining > 0 ? "重新评估这一题还剩 \(remaining) 次 · 不另扣积分" : "这一题的重新评估次数已用完，保存后只更新文字").font(V3.sans(11)).foregroundStyle(RR.mute).padding(.top, 10)
            } else {
                HStack(spacing: 10) {
                    if !editable.isEmpty && detail["recordings_deleted"]?.bool != true { Button("手动修改") { editing = true }.buttonStyle(MockButtonStyle()) }
                    if row.round.turns.contains(where: { !$0.text("raw_transcript").isEmpty }) { Button(raw ? "看修正后的识别稿" : "查看原始识别稿") { raw.toggle() }.buttonStyle(MockButtonStyle()) }
                }.padding(.top, 8)
            }
            if let prev, !editing {
                Button("‹ 上一题") { open(prev.round.main.display("id")) }.buttonStyle(.plain).font(V3.sans(11.5)).foregroundStyle(RR.mute).frame(height: 22).padding(.top, 20)
            }
        }
    }

    private func turnView(_ turn: JSONValue, position: Int) -> some View {
        let depth = max(1, turn["depth_level"]?.numberValue ?? 1)
        let label = "\(position == 0 ? "主问题" : "追问") · 第 \(Int(depth)) 层 · \(MockMap.levelName(depth))"
        let changes = turn.text("transcript_state") == "corrected" ? (turn["correction"]?["changes"]?.items ?? []).map { $0.text("corrected") } : []
        let text = raw && !turn.text("raw_transcript").isEmpty ? turn.text("raw_transcript") : turn.text("answer_text")
        let id = turn.display("id")
        let editingThis = editing && editable.contains { $0.display("id") == id }
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: label).font(V3.sans(10.5)).foregroundStyle(RR.sub).frame(height: 22).padding(.horizontal, 7).padding(.vertical, 1).background(Color(hex: 0xEFEDE7), in: RoundedRectangle(cornerRadius: 4))
            line("面试官", turn.text("content"), blue: true)
            if turn["has_recording"]?.bool == true && detail["recordings_deleted"]?.bool != true { recording(turn).padding(.leading, 52).padding(.top, 10) }
            if turn.text("answer_status") == "skipped" { line("你", "跳过了这道题", grey: true) }
            else if editingThis {
                let draft = drafts[id] ?? turn.text("answer_text")
                let original = turn.text("raw_transcript").nonEmptyValue ?? turn.text("answer_text")
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: Binding(get: { drafts[id] ?? turn.text("answer_text") }, set: { drafts[id] = $0 }))
                        .font(V3.sans(13)).scrollContentBackground(.hidden).frame(minHeight: 66).accessibilityLabel("修改识别稿")
                    Text(verbatim: (draft != turn.text("answer_text") ? "已改 · 原识别「\(MockReview.shortText(original, 18))」" : "直接改识别错的地方")
                         + (!turn.text("raw_transcript").isEmpty && draft != turn.text("raw_transcript") && MockReview.changeRatio(turn.text("raw_transcript"), draft) > 0.5 ? " · 改动较大，评估仍以修改后的文字为准" : ""))
                        .font(V3.sans(10.5)).foregroundStyle(RR.mute)
                }
                .padding(.horizontal, 12).padding(.vertical, 10).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xC9D6F3))).padding(.leading, 52).padding(.top, 12)
            } else { line("你", text, marks: raw ? [] : changes) }
        }.turnBlock()
    }

    private func line(_ who: String, _ text: String, blue: Bool = false, grey: Bool = false, marks: [String] = []) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: who).font(V3.sans(10.5)).foregroundStyle(blue ? RR.blue : RR.mute).frame(width: 52, height: 22, alignment: .leading)
            highlighted(text, marks).font(V3.sans(13)).foregroundStyle(grey ? MI.gry : RR.ink).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(.top, 12)
    }

    /// AI 修正过的识别：蓝字加下划线。
    private func highlighted(_ text: String, _ marks: [String]) -> Text {
        var out = Text(""), rest = Substring(text)
        let marks = marks.filter { !$0.isEmpty }
        while !rest.isEmpty {
            let best = marks.compactMap { mark in rest.range(of: mark).map { ($0, mark) } }.min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, _) = best else { out = out + Text(String(rest)); break }
            out = out + Text(String(rest[..<range.lowerBound])) + Text(String(rest[range])).foregroundColor(RR.blue).underline(color: RR.blue)
            rest = rest[range.upperBound...]
        }
        return out
    }

    private func recording(_ turn: JSONValue) -> some View {
        let id = turn.display("id"), on = playing == id && player.playing
        let bars: [CGFloat] = [4, 7, 11, 8, 14, 10, 5, 12, 15, 7, 4, 9, 13, 6, 3, 8, 12, 6, 10, 14, 5, 7, 11, 4, 6, 9, 12, 5, 8, 10, 4, 7, 11, 6, 9, 13, 5, 8, 4, 6, 9, 5, 7, 4, 6, 3, 5, 4]
        return HStack(spacing: 10) {
            Button {
                if on { player.stop(); playing = nil; return }
                Task {
                    do { player.stop(); playing = id; player.play(try await session.api.mockAudio(path: "/api/mock-interviews/\(detail.display("id"))/questions/\(id)/recording", method: "GET", body: nil)) }
                    catch { playing = nil; toast(("录音读取失败", "", true)) }
                }
            } label: {
                Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 10)).foregroundStyle(.white).frame(width: 26, height: 26).background(RR.ink, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(on ? "暂停录音" : "播放录音")
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                    Capsule().fill(Double(index) / Double(bars.count) <= 0.62 ? RR.blue : Color(hex: 0xC5C1B6)).frame(width: 2, height: height)
                }
            }.accessibilityHidden(true)
            Text(MockSession.mmss((turn["audio_duration_ms"]?.numberValue ?? 0) / 1000)).font(V3.sans(11)).foregroundStyle(RR.mute)
        }
    }

    // MARK: 右栏

    private func right(index: Int, next: MockReview.Row?) -> some View {
        let full = context.map(detail, current: root, phase: .done)
        let step = full.path[safe: index]
        let history = root["evaluation_history"]?.items ?? []
        let signals = (evaluation?["signals"]?.items ?? []).filter { $0.text("verdict") != "not_probed" }
        let g = MockMap.Geo(cx: 140, cy: 140, k: 0.5)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                ZStack(alignment: .bottom) {
                    MasteryMapView(width: 280, height: 290, g: g, points: full.points.map { var p = $0; p.angle -= full.rotation; return p }, sectors: [], targetLevel: target, targetLabel: nil,
                                   center: nil, path: full.path.enumerated().filter { $0.offset == index }.map(\.element), bounds: full.bounds?.map { $0 - full.rotation },
                                   labelOnly: step.map { [$0.id] } ?? [], noGap: true, dashed: false, hot: step.map { [$0.id] } ?? [], badges: false, bandLabels: false)
                    Text("在这场的图上").font(V3.sans(10.5)).foregroundStyle(RR.mute).frame(height: 22)
                }.frame(width: 280, height: 300, alignment: .top)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(evaluation?["score"]?.numberValue.map { "\(Int($0.rounded()))" } ?? "—").font(.system(size: 40, weight: .medium))
                        Text("/ 100").font(V3.sans(11.5)).foregroundStyle(RR.mute)
                    }.frame(height: 32)
                    if history.count > 1, let first = history.first?["score"]?.numberValue, let last = history.last?["score"]?.numberValue {
                        Text("修正识别后重新评估：\(Int(first.rounded())) → \(Int(last.rounded()))").font(V3.sans(11)).foregroundStyle(RR.blue).padding(.top, 8)
                    }
                    if editing { Text("改完重新评估后分数会更新").font(V3.sans(11)).foregroundStyle(RR.mute).padding(.top, 8) }
                    Button("设为下次先问 ›") { focus(row.round.topic) }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(RR.blue).frame(height: 22).padding(.top, 14)
                }.padding(.top, 14)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("面试官怎么批的").font(V3.sans(13, weight: .medium)).frame(height: 22).padding(.bottom, 14)
                ForEach(Array(signals.enumerated()), id: \.offset) { _, signal in
                    let verdict = signal.text("verdict")
                    let color = verdict == "hit" ? RR.blue : verdict == "partial" ? RR.or : MI.gry
                    HStack(alignment: .top, spacing: 4) {
                        Text(verdict == "hit" ? "✓" : verdict == "partial" ? "◐" : "—").font(V3.sans(13)).foregroundStyle(color).frame(width: 20, height: 22, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: signal.text("signal")).font(V3.sans(13, weight: .medium)).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true)
                            if !signal.text("evidence").isEmpty { Text(verbatim: signal.text("evidence")).font(V3.sans(11.5)).foregroundStyle(RR.sub).fixedSize(horizontal: false, vertical: true) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(verdict == "hit" ? "命中" : verdict == "partial" ? "部分" : "未命中").font(V3.sans(10.5)).foregroundStyle(color).frame(height: 22)
                    }.padding(.bottom, 16)
                }
                if evaluation == nil { Text("这一题没有评估结果").font(V3.sans(12.5)).foregroundStyle(MI.gry).frame(height: 22).padding(.vertical, 12) }
            }
            .padding(.top, 24).padding(.bottom, 16).overlay(alignment: .bottom) { Rectangle().fill(RR.line).frame(height: 1) }
            let highlights = evaluation?["highlights"]?.items ?? [], weaknesses = evaluation?["weaknesses"]?.items ?? []
            if evaluation != nil && (!highlights.isEmpty || !weaknesses.isEmpty) {
                HStack(alignment: .top, spacing: 20) {
                    pair("亮点", highlights.first?.stringValue ?? "—")
                    pair("待改进", weaknesses.first?.stringValue ?? "—")
                }.padding(.top, 18)
            }
            if let reference = evaluation?.text("reference_answer").nonEmptyValue {
                VStack(alignment: .leading, spacing: 10) {
                    Text("参考思路").font(V3.sans(12.5, weight: .medium)).frame(height: 22)
                    Text(verbatim: reference).font(V3.sans(12)).foregroundStyle(RR.sub).lineHeight(12, 21).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xEFEDE7), in: RoundedRectangle(cornerRadius: 10)).padding(.top, 22)
            }
            if !editing {
                HStack {
                    Button(busy == "evaluate" ? "正在评估…" : "重新评估这一题 · 还剩 \(remaining) 次") { Task { await reEvaluate() } }.buttonStyle(MockButtonStyle()).disabled(remaining <= 0 || busy != nil)
                    Spacer()
                    if let next { Button("下一题 · Q\(next.no) \(next.round.topic) ›") { open(next.round.main.display("id")) }.buttonStyle(.plain).font(V3.sans(11.5)).foregroundStyle(RR.sub).frame(height: 22) }
                }.padding(.top, 22)
            }
        }
    }

    private func pair(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(V3.sans(12, weight: .medium)).frame(height: 22)
            Text(verbatim: text).font(V3.sans(12)).foregroundStyle(RR.sub).lineHeight(12, 19).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 请求

    private var base: String { "/api/mock-interviews/\(detail.display("id"))" }
    private func call(_ path: String, _ method: String = "POST", _ body: JSONValue? = nil) async throws -> JSONValue {
        try await session.api.careerRequest(path: base + path, method: method, query: [:], body: body)
    }

    private func correct() async {
        busy = "correct"; defer { busy = nil }
        do {
            let result = try await call("/transcripts:correct")
            let changed = (result["items"]?.items ?? []).reduce(0) { $0 + ($1["changes"]?.items.count ?? 0) }
            if let next = result["mock_interview"] { updated(next) }
            toast((changed > 0 ? "已修正 \(changed) 处识别错误" : "识别稿没有需要修正的地方", "", false))
        } catch { toast(("识别稿没有修正", MockInterviewText.error(error), true)) }
    }

    private func reEvaluate() async {
        busy = "evaluate"; defer { busy = nil }
        do {
            let result = try await call("/questions/\(root.display("id"))/re-evaluate")
            if let next = result["mock_interview"] { updated(next) }
            let before = result["previous_total_score"]?.numberValue.map { "\(Int($0))" } ?? "—"
            toast(("这一题重新评估了：\(before) → \(Int((result["total_score"]?.numberValue ?? 0).rounded()))", "还剩 \(result["remaining"]?.integer ?? 0) 次", false))
        } catch { toast(("没有重新评估", MockInterviewText.error(error), true)) }
    }

    private func save() async {
        busy = "save"; defer { busy = nil }
        do {
            var latest: JSONValue?
            for turn in editable {
                let id = turn.display("id")
                guard let draft = drafts[id], draft != turn.text("answer_text") else { continue }
                latest = try await call("/questions/\(id)/transcript", "PUT", .object(["text": .string(draft)]))["mock_interview"]
            }
            if let latest { updated(latest) }
            editing = false; drafts = [:]
            if remaining > 0 {
                let result = try await call("/questions/\(root.display("id"))/re-evaluate")
                if let next = result["mock_interview"] { updated(next) }
                toast(("已保存并重新评估这一题", "还剩 \(result["remaining"]?.integer ?? 0) 次 · 不另扣积分", false))
            }
        } catch { toast(("识别稿没有保存", MockInterviewText.error(error), true)) }
    }
}

private extension View {
    /// `.mi2-qd-turn`：每轮下面一条分隔线。
    func turnBlock() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(RR.line).frame(height: 1) }.padding(.bottom, 18)
    }
}
