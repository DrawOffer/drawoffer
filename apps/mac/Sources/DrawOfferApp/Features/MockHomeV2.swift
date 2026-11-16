import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试首页（Figma 09 · 01 首页：01.01 没有简历 / 01.02 有简历没面试 / 01.03 一条 / 01.04 两条 / 01.05 多条记录；Web `v2/MockHome.tsx`）。
/// 五个状态共用一个骨架：页头写结论、操作放右上，中间固定三行录音时间线，分隔线下是四列摘要。走工作区页面宽度，不进缩放画布。
struct MockHomeV2: View {
    @Environment(SessionStore.self) private var session
    var focus: PracticeFocus?
    let open: (String) -> Void
    let openReport: (String) -> Void
    let showRecords: () -> Void
    let showSchedule: () -> Void
    let showResumes: () -> Void
    let showLibrary: () -> Void
    let showOpportunities: () -> Void
    /// 「开始」「接着练」进面试配置（02）；不传时直接开新的一场配置页由外层决定。
    var showConfig: () -> Void = {}

    private static let countWord = ["", "一", "两", "三", "四", "五", "六", "七", "八", "九"]
    private static let stopLabel = ["", "停在这里", "两次都停在这里", "每次都停在这里"]
    private static let rowOpacity = [1.0, 0.75, 0.5]
    private static let ghostFade = [0.5, 0.25, 0.12]
    private static let emptyFade = [0.6, 0.32, 0.14]
    private static let quoteW: CGFloat = 263

    struct HomeData { var overview: JSONValue; var list: [JSONValue]; var resumes: [JSONValue] }

    @State private var data: HomeData?
    @State private var failed = false
    @State private var tick = 0
    @State private var importing = false
    @State private var resumeImport = false
    @State private var notice: MockNotice?
    @State private var waitingID: String?

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private func request(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: "GET", query: query, body: nil)
    }

    private var active: JSONValue? { data?.list.first { ["in_progress", "preparing"].contains($0.text("status")) } }
    private var recent: JSONValue? { data?.list.sorted { $0.text("created_at") > $1.text("created_at") }.first }
    private var evaluating: JSONValue? { recent.flatMap { ["evaluating", "evaluation_failed"].contains($0.text("status")) ? $0 : nil } }
    private var blocking: JSONValue? { active ?? evaluating }

    var body: some View {
        GeometryReader { geometry in
            let card = geometry.size.width, gutter = V3Page<EmptyView>.gutter(card: card)
            let width = max(0, card - gutter * 2)
            // 行高跟着内容卡高度走：900 高的窗口是设计稿的 114，高屏把多出来的高度分给时间线
            let runH = min(200, max(120, (geometry.size.height - 528) / 2))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { page(width: width, runH: runH) }
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, gutter).padding(.top, 52).padding(.bottom, 60)
            }
        }
        .background(.white)
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: "\(account):\(tick)") { await load() }
        .task(id: evaluating?.text("status") == "evaluating" ? evaluating?.text("id") ?? "" : "") {
            // 评估中：5 秒刷新一次，好了提示一下
            guard let id = evaluating?.text("id"), evaluating?.text("status") == "evaluating" else { return }
            waitingID = id
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); if Task.isCancelled { return }; tick += 1 }
        }
        .onChange(of: data?.list.map { $0.text("id") + $0.text("status") } ?? []) { _, _ in
            guard let id = waitingID, data?.list.contains(where: { $0.text("id") == id && $0.text("status") == "completed" }) == true else { return }
            waitingID = nil
            notice = MockNotice(kind: .success, title: "评估报告好了", message: "这场的分数和卡住的地方已经更新")
        }
        .centeredSheet(isPresented: $importing) {
            MockImportDialog(close: { importing = false }, done: {
                importing = false
                notice = MockNotice(kind: .queued, title: "已开始生成复盘", message: "好了会出现在这里，也会记进长期记忆")
                tick += 1
            })
        }
        .centeredSheet(isPresented: $resumeImport) {
            ResumeImportSheet(close: { resumeImport = false }, accepted: { title in
                resumeImport = false
                notice = MockNotice(kind: .queued, title: "已开始导入", message: "「\(title)」解析完成后这里会更新")
                tick += 1
            })
        }
    }

    // MARK: 页面

    @ViewBuilder private func page(width: CGFloat, runH: CGFloat) -> some View {
        let overview = data?.overview
        let finished = (overview?["counts"]?["mock"]?.integer ?? 0) + (overview?["counts"]?["real"]?.integer ?? 0)
        let reviewing = overview?["records"]?.items.contains { $0.text("status") == "reviewing" } ?? false
        if let data, let overview {
            if data.resumes.isEmpty {
                head(overview, title: "先放一份简历，面试官按它出题。", desc: "面试里的问题，都从你写的经历来。\n没有现成的，现在写一份也可以。", note: "支持 PDF、Word、Markdown", width: width) {
                    Button("写第一份简历", action: showResumes).buttonStyle(MockPillStyle(kind: .ghost, height: 40))
                    Button("导入简历") { resumeImport = true }.buttonStyle(MockPillStyle(height: 40, padding: 20))
                }
                ghostRuns(runH: runH)
                tallies("有了简历，练完这里会记下", items: Self.emptyTallies, width: width)
            } else if finished == 0 {
                head(overview, title: "先有一场面试，才知道该练什么。", desc: "练一场，或者导入面过的一场。\n之后每一场，都从你卡住的地方接着问。",
                     note: reviewing ? "导入的面试正在生成复盘，好了会出现在这里。" : "录音或文字稿都可以导入。", width: width) {
                    Button("导入面试记录") { importing = true }.buttonStyle(MockPillStyle(kind: .ghost, height: 40))
                    Button(startLabel("开始第一场模拟面试"), action: start).buttonStyle(MockPillStyle(height: 40, padding: 20))
                }
                ghostRuns(runH: runH)
                tallies("练完第一场，这里会记下", items: Self.emptyTallies, width: width)
            } else {
                let stuck = overview["stuck"].flatMap { $0 == .null ? nil : $0 }
                head(overview, title: stuck.map(Self.stuckTitle) ?? "这几场没有卡住的地方。",
                     desc: stuck != nil ? "这场从这里接着问，答过去就不用再练了。" : "下一场换个方向，继续往深处问。", note: nil, width: width) {
                    Button("导入面试记录") { importing = true }.buttonStyle(MockPillStyle(kind: .ghost, height: 40))
                    Button(startLabel("开始这一场"), action: start).buttonStyle(MockPillStyle(height: 40))
                }
                stuckRuns(stuck, runH: runH)
                tallies("这 \(finished) 场记下的", items: Self.tallies(overview), width: width, records: true)
            }
        } else if failed {
            head(nil, title: "模拟面试", desc: nil, note: nil, width: width) { EmptyView() }
            VStack(alignment: .leading, spacing: 12) {
                Text("模拟面试没有加载出来").font(V3.serif(28)).foregroundStyle(MockPalette.ink)
                Text("请检查网络后重试。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                Button("重新加载") { tick += 1 }.buttonStyle(MockPillStyle(kind: .ghost))
            }.padding(.top, 12)
        } else {
            V3Loading("正在加载模拟面试…").frame(maxWidth: .infinity).padding(.top, 160)
        }
    }

    /// `.mi3-home-head`：左边眉题、标题、说明，右边操作（下面一行小字）；窄于 640 时操作换到下面。
    private func head<Actions: View>(_ overview: JSONValue?, title: String, desc: String?, note: String?, width: CGFloat, @ViewBuilder actions: () -> Actions) -> some View {
        let counts = overview.map { Self.countLine($0) } ?? ""
        let copy = VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: ["MOCK INTERVIEWS", counts].filter { !$0.isEmpty }.joined(separator: " · ")).font(V3.sans(12, weight: .medium)).foregroundStyle(MockPalette.fnt).frame(height: 18, alignment: .leading)
            Text(verbatim: title).font(V3.serif(28)).foregroundStyle(MockPalette.ink).lineHeight(28, 36).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if let desc { Text(verbatim: desc).font(V3.sans(14)).foregroundStyle(MockPalette.sub).lineHeight(14, 22).fixedSize(horizontal: false, vertical: true).padding(.top, 6) }
        }
        let side = VStack(alignment: width < 640 ? .leading : .trailing, spacing: 9) {
            HStack(spacing: 10) { actions() }
            if let note { Text(verbatim: note).font(V3.sans(13)).foregroundStyle(MockPalette.fnt).frame(height: 20) }
        }
        return Group {
            if width < 640 {
                VStack(alignment: .leading, spacing: 16) { copy; side }
            } else {
                HStack(alignment: .top, spacing: 24) { copy.layoutPriority(1); Spacer(minLength: 0); side.padding(.top, 30).fixedSize() }
            }
        }
        .frame(minHeight: 112, alignment: .topLeading)
    }

    // MARK: 时间线

    private func ghostRuns(runH: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in ghostRow(opacity: Self.emptyFade[index], shift: index, height: index == 2 ? 126 : runH) }
        }
        .padding(.top, 28).padding(.top, 12)
    }

    private func ghostRow(opacity: Double, shift: Int, height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(MockPalette.cl).frame(width: 42, height: 6)
                RoundedRectangle(cornerRadius: 2.5).fill(MockPalette.line).frame(width: 66, height: 5)
            }.padding(.top, 11).frame(width: Self.metaW, alignment: .leading)
            MockGhostRow(opacity: 1, shift: shift).padding(.trailing, 25).padding(.top, -11)
            Color.clear.frame(width: Self.quoteW)
        }
        .frame(height: height, alignment: .top).opacity(opacity)
    }

    private static let metaW: CGFloat = 154

    @ViewBuilder private func stuckRuns(_ stuck: JSONValue?, runH: CGFloat) -> some View {
        let records = Array((stuck?["records"]?.items ?? []).suffix(3).reversed())
        let rows = records.count
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: Self.mmdd(record.text("date"))).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: 22)
                            Text(verbatim: record.text("title").nonEmptyValue ?? (record.text("kind") == "real" ? "真实面试" : "模拟练习"))
                                .font(V3.sans(13)).foregroundStyle(MockPalette.fnt).lineLimit(1).frame(maxWidth: 146, alignment: .leading).frame(height: 20)
                        }.frame(width: Self.metaW, alignment: .leading)
                        MockRowVoiceprint(seed: "\(record.text("date")):\(index)", opacity: Self.rowOpacity[index]).padding(.trailing, 15).padding(.top, -9)
                        Group {
                            if let quote = record.text("quote").nonEmptyValue {
                                Text(verbatim: "“\(quote)……”").font(V3.sans(13)).foregroundStyle(index == 0 ? MockPalette.ink : MockPalette.fnt).lineHeight(13, 20)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(width: Self.quoteW, alignment: .topLeading).padding(.top, 11)
                    }
                    .frame(height: rows == 3 && index == 2 ? 126 : runH, alignment: .top)
                }
                ForEach(0..<max(0, 3 - rows), id: \.self) { index in
                    ghostRow(opacity: Self.ghostFade[index], shift: index, height: rows + index == 2 ? 126 : runH)
                }
            }
            .padding(.top, 28)
            if rows > 0 {
                // 「停在这里」那条竖线：落在声纹右端与原话之间
                Rectangle().fill(MockPalette.cl).frame(width: 1, height: runH * CGFloat(rows - 1) + 63)
                    .padding(.top, 24).padding(.trailing, Self.quoteW + 7.5)
                Text(verbatim: Self.stopLabel[rows]).font(V3.sans(12.5, weight: .medium)).foregroundStyle(MockPalette.sub).fixedSize()
                    .frame(width: 0).padding(.trailing, Self.quoteW + 8).frame(height: 18)
            }
        }
        .padding(.top, 12)
    }

    // MARK: 摘要

    private func tallies(_ title: String, items: [MockTally], width: CGFloat, records: Bool = false) -> some View {
        let columns = width < 860 ? 2 : 4
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                Spacer()
                if records { Button("全部记录 ›", action: showRecords).buttonStyle(MockLinkStyle()) }
            }.frame(height: 18)
            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 14) {
                ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(items.count, start + columns), id: \.self) { index in MockTallyCell(item: items[index]) }
                        ForEach(0..<(columns - min(columns, items.count - start)), id: \.self) { _ in Color.clear.frame(height: 1) }
                    }
                }
            }
        }
        .padding(.top, 17)
        .overlay(alignment: .top) { Rectangle().fill(MockPalette.line).frame(height: 1) }
    }

    private static let emptyTallies = [
        MockTally(value: "–", label: "不用再练", text: "答好的地方，之后就不再问。"),
        MockTally(value: "–", label: "还要补", text: "卡住的地方，下一场接着问。"),
        MockTally(value: "–", label: "回答习惯", text: "看你是先说结论，还是被追问才讲做法。"),
        MockTally(value: "–", label: "分数变化", text: "每一场的分数都记在这里。"),
    ]

    static func tallies(_ overview: JSONValue) -> [MockTally] {
        let counts = overview["counts"], t = overview["tallies"]
        let total = (counts?["mock"]?.integer ?? 0) + (counts?["real"]?.integer ?? 0)
        let first = total <= 1
        let cleared = t?["cleared"], open = t?["open"], late = t?["late"]
        let clearedCount = cleared?["count"]?.integer ?? 0, openCount = open?["count"]?.integer ?? 0
        let examples = { (value: JSONValue?) in (value?["examples"]?.items ?? []).map { $0.stringValue ?? "" }.filter { !$0.isEmpty }.joined(separator: "、") }
        var items = [
            clearedCount > 0
                ? MockTally(value: "\(clearedCount)", unit: "处", label: first ? "答好了" : "不用再练", text: examples(cleared), dot: MockPalette.blue)
                : MockTally(value: "0", unit: "处", label: first ? "答好了" : "不用再练", text: "答好的地方，之后就不再问。"),
            openCount > 0
                ? MockTally(value: "\(openCount)", unit: "处", label: "还要补", text: examples(open), dot: MockPalette.orange)
                : MockTally(value: "0", unit: "处", label: "还要补", text: "这几场没有留下要补的地方。"),
        ]
        let lateTotal = late?["total"]?.integer ?? 0, lateCount = late?["count"]?.integer ?? 0
        if first || lateTotal == 0 {
            items.append(MockTally(value: "1", unit: "场后", label: "看出回答习惯", text: "再练一场，就能看出来。"))
        } else {
            items.append(MockTally(value: "\(lateCount)", unit: "场", label: "被追问才讲做法", text: lateCount == 0 ? "每场都先说了结论，保持这个习惯。" : "这场试试先说结论。"))
        }
        if let score = t?["score"], score != .null {
            let latest = score["latest"]?.integer ?? 0, start = score["first"]?.integer ?? 0, count = score["count"]?.integer ?? 0
            let diff = latest - start
            items.append(count <= 1
                ? MockTally(value: "\(latest)", unit: "分", label: "第一场", text: "下一场开始，看得到进步。")
                : MockTally(value: "\(latest)", unit: "分", label: diff >= 0 ? "+\(diff)" : "\(diff)", tone: diff >= 0 ? MockPalette.blue : MockPalette.orange,
                            text: "从 \(start) 分\(count > 2 ? "练" : "")到 \(latest) 分，一共 \(count) 场。"))
        }
        return items
    }

    static func stuckTitle(_ stuck: JSONValue) -> String {
        let topic = stuck.text("topic"), times = stuck["times"]?.integer ?? 1
        if times >= 2 { return "\(topic)，你\(times < countWord.count ? countWord[times] : "\(times)")次都停在同一处。" }
        guard let detail = stuck.text("detail").nonEmptyValue else { return "\(topic)，你上次停在了这里。" }
        let spaced = detail.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
        return "\(topic)，你停在了\(spaced ? " " : "")\(detail)这一步。"
    }

    static func countLine(_ overview: JSONValue) -> String {
        let real = overview["counts"]?["real"]?.integer ?? 0, mock = overview["counts"]?["mock"]?.integer ?? 0
        return [real > 0 ? "面了 \(real) 场" : nil, mock > 0 ? "练了 \(mock) 场" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    static func mmdd(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let parts = Beijing.calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: 命令

    private func startLabel(_ idle: String) -> String { active != nil ? "继续这一场" : evaluating != nil ? "看上一场" : idle }

    private func start() {
        if let blocking { open(blocking.text("id")) } else { showConfig() }
    }

    private func load() async {
        guard !account.isEmpty else { return }
        do {
            async let overview = request("/api/mock-interviews/overview")
            async let list = request("/api/mock-interviews", query: ["limit": "100"])
            async let resumes = request("/api/resumes")
            let next = HomeData(overview: try await overview, list: try await list["items"]?.items ?? [], resumes: try await resumes["resumes"]?.items ?? [])
            if Task.isCancelled { return }
            data = next; failed = false
        } catch { if !Task.isCancelled && data == nil { failed = true } }
    }
}

/// 模拟面试错误文案（Web `MOCK_INTERVIEW_ERROR_MESSAGES`）。
enum MockInterviewText {
    static let messages = [
        "CREDIT_INSUFFICIENT": "积分已用完，本次 AI 请求没有发出。",
        "PAID_CREDIT_REQUIRED": "当前额度不能使用这项功能。",
        "MOCK_INTERVIEW_NOT_FOUND": "这场模拟面试不存在或已被删除。",
        "MOCK_INTERVIEW_IN_PROGRESS": "已有一场进行中的模拟面试，请先完成或放弃它。",
        "MOCK_INTERVIEW_QUESTION_MISMATCH": "题目已经变化，请刷新后再作答。",
        "MOCK_INTERVIEW_STATE_INVALID": "当前状态不能执行这个操作，请刷新后重试。",
        "MOCK_INTERVIEW_RESUME_REQUIRED": "这条求职记录没有关联简历，请另选一份简历。",
        "MOCK_INTERVIEW_RESUME_INVALID": "这份简历暂时无法用于模拟面试，请换一份或重新保存后再试。",
        "MOCK_INTERVIEW_MATERIAL_INVALID": "参考资料不可用：最多选择 10 份已解析成功的文字资料。",
        "MOCK_INTERVIEW_SOURCE_NOT_FOUND": "选择的简历、岗位或求职记录不存在。",
        "MOCK_INTERVIEW_CURSOR_INVALID": "列表翻页失败，请刷新后重试。",
        "MOCK_INTERVIEW_TURN_FAILED": "面试官没能生成回复，回答已保存，请重新生成。",
        "MOCK_INTERVIEW_SPEECH_UNAVAILABLE": "语音面试暂不可用，请改用文字面试。",
        "MOCK_INTERVIEW_SPEECH_SESSION_INVALID": "语音识别已过期，请重新录音。",
        "MOCK_INTERVIEW_SPEECH_EMPTY": "没有识别到文字，请重新录音或改用打字。",
        "MOCK_INTERVIEW_SPEECH_FAILED": "语音识别失败，请重录或改用文字。",
        "DATASET_MEDIA_STORAGE_LIMIT_REACHED": "音视频空间已满，录音无法保存。请改用文字作答，或删除不用的录音录像。",
        "MOCK_INTERVIEW_RECORDING_STORE_FAILED": "录音保存失败，请稍后重试提交。",
        "MOCK_INTERVIEW_RECORDING_DELETE_FAILED": "录音删除失败，请稍后重试。",
        "MOCK_INTERVIEW_TRANSCRIPT_ALREADY_CORRECTED": "本场识别稿已经修正过一次。",
        "MOCK_INTERVIEW_TRANSCRIPT_CORRECTION_REJECTED": "修改幅度超过原识别稿的 15%，只能修正错字和术语。",
        "MOCK_INTERVIEW_RECORDING_NOT_FOUND": "录音已删除或不存在。",
        "MOCK_INTERVIEW_RE_EVALUATE_LIMIT": "每道题最多重新评估 3 次。",
        "MOCK_INTERVIEW_ACTION_NOT_FOUND": "这条建议已经不在报告里了，请刷新后重试。",
        "MOCK_INTERVIEW_PLAN_INCOMPLETE": "面试题目没有准备完整，请重试。",
        "MOCK_INTERVIEW_TASK_INTERRUPTED": "后台任务被中断，请重试。",
        "LLM_MODEL_NOT_CONFIGURED": "AI 模型暂未配置，请稍后再试。",
        "LLM_RESPONSE_INVALID": "AI 返回的内容无法使用，请重试。",
        "VALIDATION_ERROR": "提交的内容不符合要求，请检查后重试。",
        "UNAUTHORIZED": "登录已过期，请重新登录。",
        "INTERVIEW_QUESTIONS_NOT_FOUND": "没找到面试问题，换一份文字稿试试。",
    ]
    static func error(_ error: Error) -> String {
        if case APIError.unauthorized = error { return messages["UNAUTHORIZED"]! }
        if case APIError.server(_, let code) = error, let message = messages[code] { return message }
        return "操作没有完成，请稍后重试。"
    }
}
