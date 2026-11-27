import Foundation

/// 投递详情（Figma 07N · 03–06，Web `features/interviews/progress/journey.tsx`）的文案与状态：
/// 左边只说现在该做什么——岗位、两行衬线大标题（第二行蓝＝轮到你，灰＝在等或已过去）、一句说明、一排按钮（一黑一白）；
/// 右边只放这一步的那件东西（状态图形）；底部是全程时间线。这里只算文案、选图形和排时间线，画法在 App。
public enum CareerJourneyAction: String, Sendable {
    case recordApplied, openSource, advance, schedule, reschedule, enter, openPlace, copyPlace, mock, practiceWeak
    case upload, paste, pickLibrary, retryTranscription, generateReview, openReview, openRecord
    case addWritten, openWritten, pickResume, openResume, recordOffer, decide, editOffer, reopen, backToNow
}

public struct CareerJourneyButton: Sendable, Equatable {
    public let action: CareerJourneyAction
    public let label: String
    public init(_ action: CareerJourneyAction, _ label: String) { self.action = action; self.label = label }
}

/// 右边那件东西（Figma 07N · 03「左右布局与状态图形」，24 个状态一件）。
public enum CareerJourneyFigure: String, Sendable {
    case resume, resumeBlank, sent, askDay, writtenDue, writtenList, day, dayPast, clock
    case recordEmpty, recordRunning, recordFailed, questions, reviewing, reviewFailed, review, wait
    case oral, offerBlank, offer, offerAccepted, offerDeclined, archive, archiveOpen
}

public struct CareerJourneyStep: Sendable {
    /// 补充投递信息弹窗标题旁的阶段胶囊。
    public let stage: String
    /// 大标题的两行。
    public let title: [String]
    /// 第二行的颜色：轮到你做、在等或已经过去、好消息（和第一行同色）。
    public enum Tone: Sendable { case turn, rest, plain }
    public let tone: Tone
    public let desc: String?
    public let primary: CareerJourneyButton?
    public let secondary: CareerJourneyButton?
    /// 不常用的几项放进右上角 ⋯。
    public let more: [CareerJourneyButton]
    public let figure: CareerJourneyFigure
}

/// 这一场去哪儿：现场是地点，其他是会议或作答链接。
public struct CareerJourneyPlace: Sendable, Equatable {
    public let label: String
    public let url: URL?
    public let onsite: Bool
}

public enum CareerJourney {
    // MARK: 小工具

    static let day: TimeInterval = 86_400

    public static func relativeDay(_ value: Date, now: Date, calendar: Calendar = Beijing.calendar) -> String? {
        switch CareerFormat.days(from: now, to: value, calendar: calendar) {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: return nil
        }
    }

    static func md(_ date: Date?) -> String { CareerDeckFormat.monthDay(date) }
    static func endClock(_ date: Date) -> String { let text = CareerDeckFormat.clock(date); return text == "00:00" ? "24:00" : text }

    static func modeLabel(_ session: JSONValue) -> String {
        ["video": "视频面试", "onsite": "现场面试", "phone": "电话面试"][session.text("mode")] ?? "其他方式"
    }

    static func live(_ session: JSONValue?) -> JSONValue? {
        guard let session, session.text("status") != "cancelled" else { return nil }
        return session
    }

    static func sessionDay(_ session: JSONValue) -> Date? {
        CareerApplication.date(session.text(session.text("schedule_kind") == "open_window" ? "end_at" : "start_at"))
    }

    /// 节点上的日子：有场次用场次时间，没有用进入这一阶段的时间。
    public static func stationDay(_ station: CareerStation) -> Date {
        live(station.session).flatMap(sessionDay) ?? station.start
    }

    /// Offer 日期是日历日（`YYYY-MM-DD`），也接受完整时间。
    public static func offerDate(_ raw: String) -> Date? { CareerFormat.offerDate(raw) ?? CareerApplication.date(raw) }

    static func cnCount(_ value: Int) -> String {
        if value == 2 { return "两" }
        return value >= 1 && value <= 9 ? String(Array("一二三四五六七八九")[value - 1]) : String(value)
    }

    static func interviewCount(_ deck: CareerDeck) -> Int {
        deck.stations.filter { $0.kind == .interview && live($0.session) != nil }.count
    }

    static func sourceURL(_ app: JSONValue) -> URL? {
        let value = app["job_snapshot"]?.text("source_url") ?? ""
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }

    /// 「还有 2 天」：只写一个单位，不足一小时写分钟；已过为 nil。
    public static func leftText(_ target: Date, now: Date) -> String? {
        let diff = target.timeIntervalSince(now)
        guard diff > 0 else { return nil }
        if diff >= day { return "还有 \(Int(diff / day)) 天" }
        let hours = Int(diff / 3600)
        return hours > 0 ? "还有 \(hours) 小时" : "还有 \(max(1, Int(diff / 60))) 分钟"
    }

    /// 这一场去哪儿；没填为 nil。
    public static func placeOf(_ session: JSONValue) -> CareerJourneyPlace? {
        let location = session.text("location"), meeting = session.text("meeting_url")
        if session.text("mode") == "onsite" {
            guard !location.isEmpty else { return nil }
            let query = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return CareerJourneyPlace(label: location, url: URL(string: "https://uri.amap.com/search?keyword=\(query)"), onsite: true)
        }
        return meeting.isEmpty ? nil : CareerJourneyPlace(label: meeting, url: URL(string: meeting), onsite: false)
    }

    /// 英文收尾的词后面接中文时留一个空格。
    static func spaced(_ words: String) -> String {
        guard let last = words.unicodeScalars.last, last.value >= 0x21 && last.value <= 0x7E else { return words }
        return words + " "
    }

    // MARK: 复盘结论（和报告页同一套判定，含用户改过的层）

    struct GraphQuestion {
        let index: Int
        let key: String
        let kind: String
        let parent: Int?
        let title: String
        let outcome: String
        let layered: Bool
        let depth: Int?
        let expected: Int
        let overridden: Bool
        let source: JSONValue
    }

    static func layered(_ question: JSONValue) -> Bool {
        if case .bool(let value) = question["depth_scored"] ?? .null { return value }
        return !["hr", "behavioral"].contains(question.text("category"))
    }

    static func target(_ question: JSONValue) -> Int {
        question["target_depth"]?.numberValue.map { Int($0) } ?? question["expected_depth"]?.numberValue.map { Int($0) } ?? 3
    }

    /// Web `review/model.ts` 的 `outcomeOf`。
    static func outcome(_ question: JSONValue, userDepth: Int?) -> String {
        let kind = question.text("kind").nonEmptyValue ?? "main"
        if kind == "reverse" { return "not_judged" }
        if userDepth == nil, let value = question.text("outcome").nonEmptyValue { return value }
        if question.text("answer_status") == "missing" { return "unrecorded" }
        if question.text("answer_status") == "declined" && userDepth == nil { return "missed" }
        if !layered(question) && userDepth == nil {
            let verdicts = (question["signals"]?.items ?? []).map { $0.text("verdict") }.filter { $0 != "not_probed" }
            guard !verdicts.isEmpty else { return "unrecorded" }
            let share = verdicts.reduce(0.0) { $0 + ($1 == "hit" ? 1 : $1 == "partial" ? 0.5 : 0) } / Double(verdicts.count)
            return share >= 0.67 ? "reached" : share >= 0.34 ? "one_short" : "missed"
        }
        guard let depth = userDepth ?? question["achieved_depth"]?.numberValue.map({ Int($0) }) else { return "unrecorded" }
        let gap = target(question) - depth
        return gap <= 0 ? "reached" : gap == 1 ? "one_short" : "missed"
    }

    static func graph(_ session: JSONValue) -> [GraphQuestion]? {
        let report = session["review_report"] ?? .null
        guard CareerReview.isV2(report) else { return nil }
        var notes: [String: Int] = [:]
        for note in session["review_question_notes"]?.items ?? [] {
            if let depth = note["user_depth"]?.numberValue { notes[note.text("question_key")] = Int(depth) }
        }
        return (report["questions"]?.items ?? []).enumerated().map { position, source in
            let kind = source.text("kind").nonEmptyValue ?? "main"
            let raw = source.text("question").trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = raw.replacingOccurrences(of: "[？?。.！!]+$", with: "", options: .regularExpression)
            let short = clean.count > 10 ? String(clean.prefix(10)) + "…" : clean
            let userDepth = notes[source.text("key")]
            return GraphQuestion(index: source["index"]?.numberValue.map { Int($0) } ?? position + 1, key: source.text("key"), kind: kind,
                                 parent: kind == "follow_up" ? source["parent"]?.numberValue.map { Int($0) } : nil,
                                 title: kind == "reverse" ? "反问" : source.text("title").trimmingCharacters(in: .whitespaces).nonEmptyValue ?? short,
                                 outcome: outcome(source, userDepth: userDepth), layered: layered(source),
                                 depth: userDepth ?? source["achieved_depth"]?.numberValue.map { Int($0) },
                                 expected: target(source), overridden: userDepth != nil, source: source)
        }
    }

    /// Web `chartLevel`：图上这一题到了第几层。
    static func chartLevel(_ question: GraphQuestion) -> Int? {
        if question.outcome == "unrecorded" || question.outcome == "not_judged" { return nil }
        if question.layered { return max(0, min(5, question.depth ?? 0)) }
        let drop = question.outcome == "reached" ? 0 : question.outcome == "one_short" ? 1 : 2
        return max(0, min(5, question.expected - drop))
    }

    /// 复盘里的一道主问题（连同它的追问算一题，和报告页同一个数法）。
    public struct ReviewedQuestion: Sendable, Equatable, Identifiable {
        public let id: String
        public let no: Int
        public let title: String
        public let outcome: String
        /// 没答好时是该补的那句，答到位时是亮点。
        public let line: String?
        public let level: Int?
        public let expected: Int
        /// 最后一问的原话，带去模拟面试。
        public let ask: String
        /// 没说到或只说了一半的点。
        public let gaps: [String]
        public var weak: Bool { outcome == "missed" || outcome == "one_short" }
    }

    /// Web `reviewedQuestions`：复盘里的主问题（含用户改过的判定），没记下的不算；没有逐题判断的旧复盘为空。
    public static func reviewedQuestions(_ session: JSONValue?) -> [ReviewedQuestion] {
        guard let session, let questions = graph(session) else { return [] }
        let charted = questions.filter { $0.kind != "reverse" }
        let mains = charted.filter { ($0.kind == "main" || $0.parent == nil) && $0.source["intro"]?.bool != true }
        return mains.enumerated().map { position, main in
            let unit = [main] + charted.filter { $0.parent == main.index }
            let unitOutcome = main.source.text("unit_outcome").nonEmptyValue ?? main.outcome
            let outcome = main.overridden ? main.outcome : unitOutcome == "not_judged" ? "unrecorded" : unitOutcome
            let weak = outcome == "missed" || outcome == "one_short"
            let improvement = unit.lazy.compactMap { $0.source.text("improvement").nonEmptyValue }.first
            let strength = unit.lazy.compactMap { $0.source.text("strength").nonEmptyValue }.first
            let levels = unit.compactMap(chartLevel)
            var seen = Set<String>(), gaps: [String] = []
            for item in unit {
                for signal in item.source["signals"]?.items ?? [] {
                    let label = (signal.text("label").nonEmptyValue ?? signal.text("signal")).trimmingCharacters(in: .whitespaces)
                    guard signal.text("verdict") != "not_probed", !label.isEmpty, seen.insert(label).inserted else { continue }
                    if signal.text("verdict") != "hit" { gaps.append(label) }
                }
            }
            return ReviewedQuestion(id: String(main.index), no: position + 1, title: main.title, outcome: outcome,
                                    line: weak ? improvement ?? strength : strength ?? improvement,
                                    level: main.overridden ? chartLevel(main) : levels.max(), expected: main.expected,
                                    ask: unit.last?.source.text("question") ?? main.title, gaps: gaps)
        }.filter { $0.outcome != "unrecorded" }
    }

    public static func weakQuestions(_ session: JSONValue?) -> [ReviewedQuestion] { reviewedQuestions(session).filter(\.weak) }
    public static func missedCount(_ session: JSONValue?) -> Int { weakQuestions(session).count }

    /// 一次最多带三题去练。
    public static let practiceLimit = 3

    /// Web `ReviewBand.reviewHeadline`：结论一句与「差一层 / 答到位 / 没记下各几题」。
    public static func reviewHeadline(_ session: JSONValue) -> (title: String, detail: String) {
        let report = session["review_report"] ?? .null
        guard let questions = graph(session) else {
            let text = report.text("summary").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue
                ?? session.text("review_summary").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? "复盘已生成"
            return (text.count > 22 ? String(text.prefix(22)) + "…" : text, "点开看每道题的分析")
        }
        let marks = questions.map { $0.outcome == "reached" ? "good" : $0.outcome == "one_short" ? "shallow" : $0.outcome == "missed" ? "missed" : "unrecorded" }
        let count = { (kind: String) in marks.filter { $0 == kind }.count }
        let missedIndex = marks.firstIndex(of: "missed"), shallowIndex = marks.firstIndex(of: "shallow")
        let title = missedIndex.map { "\(count("missed")) 题没答上：\(questions[$0].title)" }
            ?? shallowIndex.map { "\(count("shallow")) 题差一层：\(questions[$0].title)" } ?? "每道题都答到了位"
        let detail = [
            count("shallow") > 0 && missedIndex != nil ? "差一层 \(count("shallow"))" : nil,
            count("good") > 0 ? "答到位 \(count("good"))" : nil,
            count("unrecorded") > 0 ? "没记下 \(count("unrecorded"))" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return (title, detail.isEmpty ? report.text("headline") : detail)
    }

    // MARK: 面试记录状态（Web `StationCard.recordState`）

    public enum RecordState: Sendable, Equatable {
        case none
        case ready(questions: Int, source: String)
        case transcribing(file: String, minutes: Int?)
        case failed(file: String, datasetID: String)
    }

    public static func markdown(_ session: JSONValue, _ detail: JSONValue?) -> String {
        detail?["session"]?.text("questions_markdown").nonEmptyValue ?? session.text("questions_markdown")
    }

    public static func recordState(_ session: JSONValue, _ detail: JSONValue?) -> RecordState {
        let questions = InterviewRecord.parse(markdown(session, detail))
        let transcriptions = detail?["session"]?["transcriptions"]?.items ?? session["transcriptions"]?.items ?? []
        let assets = detail?["assets"]?.items ?? []
        let name = { (id: String) in assets.first { $0.text("id") == id }?.text("original_file_name").nonEmptyValue ?? "录音" }
        if !questions.isEmpty {
            return .ready(questions: questions.count, source: session.text("transcript_source") == "transcription" ? "录音转写" : "文字整理")
        }
        if let active = transcriptions.first(where: { ["queued", "running"].contains($0.text("status")) }) {
            let id = active.text("dataset_id")
            let duration = assets.first { $0.text("id") == id }?["duration_ms"]?.numberValue
            return .transcribing(file: name(id), minutes: duration.map { max(1, Int(($0 / 600_000).rounded())) })
        }
        if let failed = transcriptions.first(where: { $0.text("status") == "failed" }) {
            return .failed(file: name(failed.text("dataset_id")), datasetID: failed.text("dataset_id"))
        }
        return .none
    }

    // MARK: Offer

    static func money(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard let amount = Double(raw) else { return raw }
        return amount >= 1000 && amount.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(amount / 1000))K" : (amount == amount.rounded() ? String(Int(amount)) : String(amount))
    }

    static func offerMonths(_ app: JSONValue) -> Int? {
        let text = app.text("offer_benefits_description")
        guard let range = text.range(of: "(\\d{2})\\s*薪", options: .regularExpression) else { return nil }
        return Int(text[range].prefix(2))
    }

    /// Web `offerSalaryUnit`：数字后面写明「元 / 月」「K / 年」。
    public static func offerSalaryUnit(_ amount: String, currency: String, period: String) -> String {
        let code = (currency.isEmpty ? "CNY" : currency).uppercased()
        let money = code == "CNY" ? (amount.hasSuffix("K") ? "" : "元") : code
        let per = period == "year" ? "/ 年" : period == "month" ? "/ 月" : ""
        return [money, per].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 「22K × 15」（做决定弹窗）。
    public static func offerSalary(_ app: JSONValue) -> String? {
        guard let salary = money(app.display("offer_salary")) else { return nil }
        return salary + (offerMonths(app).map { " × \($0)" } ?? "")
    }

    public static func dotDate(_ raw: String) -> String? {
        guard let date = offerDate(raw) else { return nil }
        let parts = Beijing.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0).\(CareerDeckFormat.two(parts.month ?? 0)).\(CareerDeckFormat.two(parts.day ?? 0))"
    }

    public struct OfferText: Sendable, Equatable {
        public let job: String
        public let salary: String?
        public let detail: String?
        public let due: String?
        public let done: String?
    }

    /// Web `offerText`：Offer 图形上的几行。
    public static func offerText(_ app: JSONValue) -> OfferText {
        let amount = money(app.display("offer_salary"))
        let months = offerMonths(app)
        let unit = amount.map { offerSalaryUnit($0, currency: app.text("offer_salary_currency"), period: app.text("offer_salary_period")) } ?? ""
        let salary = amount.map { amount in
            months != nil && app.text("offer_salary_period") != "year" ? "\(amount) × \(months!)" : [amount, unit].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let detail = [dotDate(app.text("offer_start_on")).map { "\($0) 入职" }, app.text("offer_base_location").nonEmptyValue].compactMap { $0 }.joined(separator: " · ")
        return OfferText(job: "\(app.text("company_name_snapshot")) · \(app.text("job_title_snapshot"))", salary: salary, detail: detail.nonEmptyValue,
                         due: CareerFormat.offerDate(app.text("offer_reply_due_on")).map { "\(md($0)) 前答复" },
                         done: CareerApplication.date(app.text("terminated_at")).map { "\(md($0)) 接受" })
    }

    /// 收进盒子里的标签：「2 轮记录」/「投递记录」。
    public static func roundLabel(_ deck: CareerDeck) -> String {
        let rounds = deck.stations.filter { ($0.kind == .interview || $0.kind == .written) && $0.session != nil }.count
        return rounds > 0 ? "\(rounds) 轮记录" : "投递记录"
    }

    // MARK: 这一步

    static func matchDesc(_ match: JobMatch?) -> String? {
        guard let match, let score = match.score else { return nil }
        let covered = match.covered.prefix(3), missing = match.missing.prefix(2)
        return "这份和岗位匹配 \(score) 分" + (covered.isEmpty ? "" : "，\(spaced(covered.joined(separator: "、")))都对得上")
            + (missing.isEmpty ? "" : "，还缺 \(missing.joined(separator: "、"))") + "。"
    }

    static func coverageDesc(_ match: JobMatch?) -> String? {
        guard let match, match.score != nil, !(match.covered.isEmpty && match.missing.isEmpty) else { return nil }
        return "岗位提到 \(match.covered.count + match.missing.count) 项技能，简历写到了 \(match.covered.count) 项。"
            + (match.missing.isEmpty ? "" : "还没写到的是 \(match.missing.prefix(3).joined(separator: "、"))。")
    }

    public static func step(application app: JSONValue, deck: CareerDeck, station: CareerStation, viewing: Bool, now: Date,
                            detail: JSONValue?, previous: CareerStation?, reviewCost: String?, match: JobMatch? = nil, memoryTopics: Int = 0) -> CareerJourneyStep {
        typealias B = CareerJourneyButton
        func make(_ stage: String, _ title: [String], _ tone: CareerJourneyStep.Tone, _ desc: String?, primary: B? = nil, secondary: B? = nil,
                  more: [B] = [], _ figure: CareerJourneyFigure) -> CareerJourneyStep {
            CareerJourneyStep(stage: stage, title: title, tone: tone, desc: desc, primary: primary, secondary: secondary, more: more, figure: figure)
        }
        let advance = B(.advance, "更新进度")
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        let backToNow = B(.backToNow, "回到" + (deck.pending ? "待投递" : current.short))
        let session = live(station.session)
        let place = session.flatMap(placeOf)
        let copyPlace = place.map { [B(.copyPlace, $0.onsite ? "复制地点" : "复制链接")] } ?? []
        let resumeID = app.text("resume_id").nonEmptyValue ?? app.display("resume_id").nonEmptyValue
        let seeResume = resumeID != nil ? B(.openResume, "查看简历") : nil
        let seeRecord = B(.openRecord, "查看面试记录")
        let anyReview = deck.stations.reversed().first { CareerDeck.hasReview($0.session) }?.session
        let resumeTitle = app.text("resume_title_snapshot")

        // 已结束
        if let ended = deck.ended, !viewing {
            let last = deck.stations[deck.stations.count - 1]
            let interviews = interviewCount(deck)
            let walked = interviews > 0 ? "走了 \(deck.days) 天、\(cnCount(interviews))场面试" : "走了 \(deck.days) 天"
            let review = anyReview != nil ? B(.openReview, "查看复盘") : nil
            switch ended.kind {
            case .withdrew:
                return make("已结束", ["这个岗位", "先不继续了"], .rest, "\(md(ended.at)) 停在\(last.short)。想回来随时可以恢复，之前的记录都在。",
                            primary: B(.reopen, "恢复投递"), secondary: review, .archiveOpen)
            case .accepted:
                let start = CareerFormat.offerDate(app.text("offer_start_on")).map { Beijing.calendar.dateComponents([.year, .month], from: $0) }
                return make("已接受", ["Offer 接受了", "恭喜"], .plain,
                            start.map { "\($0.year ?? 0) 年 \($0.month ?? 0) 月入职。\(walked)，记录都留着。" } ?? "\(walked)，记录都留着。", primary: review, .offerAccepted)
            case .declined:
                return make("已婉拒", ["这份 Offer", "婉拒了"], .rest, "\(md(ended.at)) 婉拒的。\(walked)，记录都留着。", primary: review, .offerDeclined)
            case .rejected:
                return make("没通过", ["走到\(last.short)", "记录都留着"], .rest,
                            anyReview != nil ? "\(walked)。没答好的地方，下次面试前会先提醒你。" : "\(walked)，之后的投递还能参考。", primary: review, .archive)
            case .other:
                return make("已结束", ["这条投递", "结束了"], .rest, "\(walked)，记录都留着。", primary: review, .archive)
            }
        }

        if station.kind == .apply && deck.pending {
            let change = resumeTitle.isEmpty ? nil : B(.pickResume, "换一份简历")
            let source = sourceURL(app) != nil ? B(.openSource, "去官网投递") : nil
            return make("待投递", ["选一份简历", "投出去"], .turn,
                        resumeTitle.isEmpty ? "记录投递时选一份，之后的准备和复盘都会参考它。" : matchDesc(match) ?? "投完回来记一笔，之后的进展都从这里往下走。",
                        primary: B(.recordApplied, "记录投递"), secondary: source ?? change, more: source != nil ? [change].compactMap { $0 } : [], .resume)
        }

        if station.kind == .apply {
            let channel = CareerDeck.source(app)
            return make("投递 · \(md(station.start))", [md(station.start), channel.map { "在\($0)投出去" } ?? "投出去"], .rest,
                        resumeTitle.isEmpty ? nil : "投的是「\(resumeTitle)」。", primary: seeResume, secondary: backToNow, resumeID != nil ? .resume : .resumeBlank)
        }

        if station.kind == .screening {
            if station.current && !viewing {
                let days = CareerDeckFormat.dayCount(station.start, now)
                let noResume = resumeTitle.isEmpty
                return make("筛选中", days > 0 ? ["投出去 \(days) 天了", "还在等结果"] : ["今天投出去了", "等结果"], .rest,
                            noResume ? "还没记投的是哪份简历，补上之后复盘会更准。" : coverageDesc(match) ?? "收到笔试或面试通知，回来记一笔。",
                            primary: advance, secondary: noResume ? B(.pickResume, "选一份简历") : seeResume, noResume ? .resumeBlank : .sent)
            }
            let failed = station.result == "rejected"
            return make("筛选 · " + (failed ? "没通过" : "已通过"), ["简历筛选", failed ? "没通过" : "通过了"], .rest,
                        station.end.map { "投出去 \(CareerDeckFormat.dayCount(station.start, $0)) 天后出结果。" }, primary: seeResume, secondary: backToNow, .sent)
        }

        if station.kind == .oc {
            let at = CareerApplication.date(app.text("oc_communicated_at")) ?? station.start
            if station.current && !viewing {
                return make("口头 Offer", ["口头 Offer 有了", "等正式的"], .rest, "收到正式 Offer 后在这里记下，薪资和答复截止都放在一起。",
                            primary: B(.recordOffer, "记录正式 Offer"), .oral)
            }
            return make("口头 Offer · \(md(at))", ["拿到了", "口头 Offer"], .rest, "\(md(at)) 沟通，之后转成了正式 Offer。", secondary: backToNow, .oral)
        }

        if station.kind == .offer {
            guard app.text("offer_status") != "none" else {
                return make("正式 Offer", ["Offer 到了", "把条件记下来"], .turn, "薪资、入职和答复截止填进来，做决定时一眼看全。",
                            primary: B(.editOffer, "填写 Offer"), .offerBlank)
            }
            let due = CareerFormat.offerDate(app.text("offer_reply_due_on"))
            let left = due.map { CareerFormat.days(from: now, to: $0) }
            let title: [String] = left.map { $0 > 0 ? ["还有 \($0) 天", "决定去不去"] : $0 == 0 ? ["今天要答复", "决定去不去"] : ["过了答复日期", "记下你的决定"] }
                ?? ["Offer 到了", "决定去不去"]
            return make("正式 Offer · 待答复", title, .turn, "接受之后，其他还在进行的投递不会自动结束。",
                        primary: B(.decide, "做决定"), secondary: B(.editOffer, "编辑 Offer"), .offer)
        }

        // 笔试 / 测评 / 面试
        let written = station.kind == .written
        let isNow = station.current && !viewing

        if isNow && session == nil && deck.stageState == "awaiting_schedule" {
            let waited = CareerDeckFormat.dayCount(station.start, now)
            let passed = previous?.kind == .interview ? previous : nil
            let desc = written ? "把作答时段和链接填进来，截止前会出现在面试日程里。"
                : (passed.map { "\($0.short) \(md(stationDay($0))) 通过" } ?? "\(md(station.start)) 收到通知") + (waited > 0 ? "，已经等了 \(waited) 天。" : "。") + "定下来就填上。"
            return make("\(station.short) · 时间待安排", ["\(spaced(station.short))来了", "先定时间"], .turn, desc, primary: B(.schedule, "安排时间"), .askDay)
        }

        if isNow, let session, session.text("status") == "scheduled", let end = CareerApplication.date(session.text("end_at")), end > now {
            let start = CareerApplication.date(session.text("start_at")) ?? end
            let meeting = !session.text("meeting_url").isEmpty
            let openPlace = place?.onsite == true ? B(.openPlace, "查看地点") : nil
            let dated = { (value: Date) in (relativeDay(value, now: now) ?? "\(md(value)) ") + station.short }
            if written || session.text("schedule_kind") == "open_window" {
                let open = session.text("schedule_kind") == "open_window"
                let left = leftText(open ? end : start, now: now)
                let today = relativeDay(open ? end : start, now: now) == "今天"
                let fill = place == nil && session.text("mode") != "onsite" ? B(.reschedule, "填上\(station.short)链接") : nil
                let title: [String] = left == nil ? [station.short, "进行中"]
                    : open ? [today ? "今天 \(endClock(end)) 前" : left!, "把\(station.short)做完"] : [dated(start), left!]
                let desc: String? = place?.onsite == true ? "地点在\(place!.label)。"
                    : left == nil || open ? "找一段不被打断的时间，做完回来把题目记下。"
                    : fill != nil ? "先把链接填上，到点从这里直接进。" : place != nil ? "提前几分钟进去，把环境试一下。" : nil
                return make("\(station.short) · " + (session.text("mode") == "onsite" ? "现场" : "线上"), title, .turn, desc,
                            primary: openPlace ?? (meeting ? B(.enter, "进入\(station.short)") : left != nil || open ? fill : advance),
                            more: copyPlace, .writtenDue)
            }
            let today = relativeDay(start, now: now) == "今天"
            let prevWeak = previous?.kind == .interview ? missedCount(previous?.session) : 0
            let stage = "\(station.short) · \(modeLabel(session))"
            let mock = B(.mock, "模拟这场面试")
            if today || start <= now {
                let left = leftText(start, now: now)
                let enter = openPlace ?? (meeting ? B(.enter, "进入会议") : nil)
                return make(stage, left.map { [dated(start), $0] } ?? [station.short, "进行中"], .turn,
                            left == nil ? "面完回来，趁热把问了什么记下来。" : prevWeak > 0 ? "\(previous!.short)没答好的 \(prevWeak) 题，进去前再看一眼。" : "提前几分钟进去，把设备试一下。",
                            primary: enter ?? (left != nil ? mock : advance), secondary: enter != nil && left != nil ? mock : nil, more: copyPlace, .clock)
            }
            let desc = memoryTopics > 1 ? "台历上几处之前没答稳，点一处就能单独练。"
                : memoryTopics == 1 ? "台历上这处之前没答稳，点一下就能单独练。"
                : prevWeak > 0 ? "\(previous!.short)没答好的几处先练。" : "按这个岗位和你的简历练一遍。"
            return make(stage, [dated(start), "先练一场"], .turn, desc,
                        primary: mock, secondary: openPlace ?? (meeting ? B(.enter, "打开会议链接") : nil), more: copyPlace, .day)
        }

        if let session {
            let record = recordState(session, detail)
            let rejected = station.result == "rejected"
            let pastTitle = [station.short, rejected ? "没通过" : "通过了"]
            let pastStage = "\(station.short) · \(md(stationDay(station))) · " + (rejected ? "没通过" : "已通过")
            if written {
                let questions = detail?["session"]?["written_questions"]?.items ?? session["written_questions"]?.items ?? []
                let wrong = questions.filter { $0.text("correctness") == "wrong" }.count
                let desc = questions.isEmpty ? "趁还记得，把题目记下来，之后能逐题标对错。"
                    : wrong > 0 ? "记了 \(questions.count) 道题，\(wrong) 道没做对。" : "记了 \(questions.count) 道题。"
                let see = questions.isEmpty ? nil : B(.openWritten, "查看\(station.short)题")
                let add = B(.addWritten, "添加\(station.short)题")
                if isNow {
                    return make("\(station.short) · 等结果", ["\(spaced(station.short))做完了", "等结果"], .rest, desc,
                                primary: advance, secondary: see ?? add, more: see != nil ? [add] : [], .writtenList)
                }
                return make(pastStage, pastTitle, .rest, questions.isEmpty ? nil : desc, primary: see, secondary: backToNow, more: [add], .writtenList)
            }
            let reviewed = session.text("review_status") != "failed" && session.text("review_status") != "generating" && CareerDeck.hasReview(session)
            let judged = reviewed ? reviewedQuestions(session) : []
            let missed = judged.filter(\.weak).count
            let paste = B(.paste, "粘贴文字")
            let library = B(.pickLibrary, "从资料库选录音")
            let replace = B(.upload, "换一份录音")
            let ready: Int? = { if case .ready(let count, _) = record { return count }; return nil }()
            let recordMore = ready != nil ? [seeRecord] : []
            let practice = B(.practiceWeak, missed > practiceLimit ? "先练 \(practiceLimit) 题" : "练这 \(missed) 题")
            if isNow {
                let done = "\(station.short) · 已面完", waiting = "\(station.short) · 等结果"
                let seeReview = B(.openReview, "查看复盘")
                if reviewed && missed > 0 {
                    return make(waiting, ["\(missed) 题没答到位", "先补上"], .turn, "趁还记得，把它们再答一遍，下一轮可能还会问到。",
                                primary: practice, secondary: seeReview, more: recordMore, .review)
                }
                if reviewed {
                    return make(waiting, [judged.isEmpty ? "复盘好了" : "都答到位了", "等结果"], .rest, "收到通知后，回来记一笔。",
                                primary: advance, secondary: seeReview, more: recordMore, .review)
                }
                if session.text("review_status") == "generating" {
                    return make(done, ["正在复盘", "稍等一会儿"], .rest, "一般 1 分钟左右，好了这里会更新，可以先去做别的。",
                                secondary: ready != nil ? seeRecord : nil, .reviewing)
                }
                if let ready {
                    let failed = session.text("review_status") == "failed"
                    return make(done, failed ? ["复盘没生成", "再试一次"] : ["记下 \(ready) 道题", "可以复盘了"], .turn,
                                failed ? "记录都还在，直接再试一次就行。" : "逐题对照你的回答，标出哪里没答到位、该怎么补。",
                                primary: B(.generateReview, failed ? "再试一次" : ["生成复盘", reviewCost].compactMap { $0 }.joined(separator: " · ")),
                                secondary: seeRecord, failed ? .reviewFailed : .questions)
                }
                switch record {
                case .transcribing(_, let minutes):
                    return make(done, ["录音正在", "整理成题目"], .rest, minutes.map { "大约要 \($0) 分钟，可以先去做别的。" } ?? "好了会按题拆开，可以先去做别的。",
                                secondary: replace, .recordRunning)
                case .failed:
                    return make(done, ["录音没转成功", "再试一次"], .turn, "还不行的话，换一份录音，或者直接粘贴文字。",
                                primary: B(.retryTranscription, "重新转写"), secondary: replace, more: [paste, library], .recordFailed)
                default:
                    return make(done, ["\(spaced(station.short))面完了", "趁热记下来"], .turn, "录音会自动转成文字、按题拆开，再用来复盘。",
                                primary: B(.upload, "上传录音"), secondary: paste, more: [library], .recordEmpty)
                }
            }
            // 回看过去的一轮
            if session.text("review_status") == "generating" {
                return make(pastStage, pastTitle, .rest, "正在逐题复盘，好了这里会更新。", secondary: backToNow, more: recordMore, .reviewing)
            }
            if reviewed {
                return make(pastStage, judged.isEmpty ? pastTitle : [spaced(station.short) + pastTitle[1], missed > 0 ? "\(missed) 题没答到位" : "都答到位了"], .rest,
                            reviewHeadline(session).detail, primary: B(.openReview, "查看复盘"), secondary: backToNow, more: recordMore, .review)
            }
            switch record {
            case .ready(let count, _):
                return make(pastStage, pastTitle, .rest, "记了 \(count) 道题，还没复盘。", primary: seeRecord, secondary: backToNow, .questions)
            case .transcribing:
                return make(pastStage, pastTitle, .rest, "录音正在转成文字，好了会按题拆开。", secondary: backToNow, more: [replace], .recordRunning)
            case .failed:
                return make(pastStage, pastTitle, .rest, "这一轮的录音没转成功。", primary: B(.retryTranscription, "重新转写"), secondary: backToNow,
                            more: [replace, paste, library], .recordFailed)
            case .none:
                return make(pastStage, pastTitle, .rest, "这一轮还没有面试记录，现在补也来得及。", primary: B(.upload, "上传录音"), secondary: backToNow,
                            more: [paste, library], .recordEmpty)
            }
        }

        if isNow {
            return make("\(station.short) · 等结果", [station.short, "在等结果"], .rest, "收到通知后，回来记一笔。", primary: advance, .wait)
        }
        let failed = station.result == "rejected"
        return make("\(station.short) · " + (failed ? "没通过" : "已通过"), [station.short, failed ? "没通过" : "通过了"], .rest, "这一轮没有记下时间。",
                    secondary: backToNow, .dayPast)
    }

    /// 还能往下走的阶段：筛选、笔试、面试。待投递、口头和正式 Offer 有各自的按钮。
    public static func canAdvance(_ deck: CareerDeck, viewing: Bool) -> Bool {
        guard deck.ended == nil, !deck.pending, !viewing else { return false }
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        return [.screening, .written, .interview].contains(current.kind)
    }

    // MARK: 右侧图形要的数据

    public struct PaperRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// 这题在完整记录里的位置，用来打开记录。
        public let position: Int
    }

    /// 有记录的一轮按考点列题；考点还没整理好时先按题列。反问不算考点。
    public static func paperRows(_ questions: [RecordQuestion], groups: [JSONValue]?) -> [PaperRow] {
        let mains = questions.enumerated().filter { $0.element.reply == nil && $0.element.question.trimmingCharacters(in: .whitespaces).range(of: "^反问[：:]", options: .regularExpression) == nil }
        func title(_ position: Int, _ question: String) -> String { question.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? "第 \(position + 1) 题" }
        guard let groups else { return mains.map { PaperRow(id: String($0.offset), title: title($0.offset, $0.element.question), position: $0.offset) } }
        return groups.compactMap { group in
            let first = (group["questions"]?.items ?? []).compactMap { $0.numberValue.map { Int($0) } }
                .lazy.compactMap { $0 >= 1 && $0 <= mains.count ? mains[$0 - 1] : nil }.first
            guard let first else { return nil }
            let topic = group.text("topic").trimmingCharacters(in: .whitespacesAndNewlines)
            return PaperRow(id: "\(group.text("topic"))-\(first.offset)", title: topic.nonEmptyValue ?? title(first.offset, first.element.question), position: first.offset)
        }
    }

    /// 送去整理考点的题目（反问除外，最多 60 题）。
    public static func topicQuestions(_ questions: [RecordQuestion]) -> [String] {
        questions.filter { $0.reply == nil && $0.question.trimmingCharacters(in: .whitespaces).range(of: "^反问[：:]", options: .regularExpression) == nil }
            .prefix(60).map { String($0.question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)).nonEmptyValue ?? "（没记下问题）" }
    }

    public enum PaperMark: Sendable { case open, good, weak, waiting }

    /// 复盘进行中：已经列出来的主问题和各题的判断；还没列出来时为空。
    public static func progressQuestions(_ session: JSONValue?) -> [(id: String, title: String, mark: PaperMark)] {
        (session?["review_progress"]?["questions"]?.items ?? []).filter { $0.text("kind") == "main" }.map { item in
            let outcome = item.text("outcome")
            return ("progress-\(item.display("index"))", item.text("title"),
                    outcome == "reached" ? .good : outcome == "missed" || outcome == "one_short" ? .weak : .waiting)
        }
    }

    /// 准备投的那份简历：版式是示意，姓名、板块和经历取自这份简历（`GET /api/resumes/{id}` 的 `resume.data`）。
    public struct ResumeSketch: Sendable, Equatable {
        public struct Entry: Sendable, Equatable { public let title: String; public let period: String }
        public struct Section: Sendable, Equatable { public let title: String; public let entries: [Entry] }
        public let name: String?
        public let headline: String?
        public let sections: [Section]
        public let skillsTitle: String?
    }

    public static func resumeSketch(_ doc: JSONValue?) -> ResumeSketch? {
        guard let doc, case .object = doc else { return nil }
        func value(_ item: JSONValue?) -> String? { item?.text("value").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue }
        let all = doc["sections"]?.items ?? []
        let sections: [ResumeSketch.Section] = all.filter { !["profile", "skills"].contains($0.text("semantic_kind")) && !($0["entries"]?.items ?? []).isEmpty }
            .compactMap { section in
                let entries = (section["entries"]?.items ?? []).prefix(2).compactMap { entry -> ResumeSketch.Entry? in
                    let fields = entry["fields"]
                    let title = [value(fields?["organization"]) ?? value(fields?["college"]), value(fields?["role"]) ?? value(fields?["name"]) ?? value(fields?["major"])]
                        .compactMap { $0 }.joined(separator: " · ")
                    let period = [value(fields?["start_date"]), value(fields?["end_date"])].compactMap { $0 }.joined(separator: " – ")
                    return title.isEmpty ? nil : ResumeSketch.Entry(title: title, period: period)
                }
                guard let title = value(section["title"]), !entries.isEmpty else { return nil }
                return ResumeSketch.Section(title: title, entries: Array(entries))
            }
        let name = value(doc["identity"]?["name"])
        guard name != nil || !sections.isEmpty else { return nil }
        return ResumeSketch(name: name, headline: value(doc["identity"]?["headline"]), sections: Array(sections.prefix(3)),
                            skillsTitle: value(all.first { $0.text("semantic_kind") == "skills" }?["title"]))
    }

    // MARK: 全程时间线

    public struct Node: Identifiable, Sendable {
        public enum Kind: Sendable { case past, current, future, failed }
        public let id: String
        public let label: String
        public let line: String?
        /// 「3 题没答到位」，带橙点。
        public let note: String?
        public let kind: Kind
        /// 可以点开回看的站点。
        public let stationID: String?
        public let day: Date?
    }

    public struct Segment: Sendable {
        public enum Style: Sendable { case past, current, future }
        public let style: Style
        public let days: Int?
    }

    /// 「今天」：蓝线走到的地方，落在第几段的哪个位置；天数是蓝线上写的。
    public struct Today: Sendable, Equatable {
        public let segment: Int
        public let ratio: Double
        public let days: Int?
    }

    public struct Timeline: Sendable {
        public let head: String
        public let nodes: [Node]
        public let segments: [Segment]
        public let today: Today?
        /// 这一轮就在今天：节点自己是今天的点，不另画。
        public let todayNode: String?
    }

    static func nodeLine(_ station: CareerStation, deck: CareerDeck, now: Date, isLast: Bool) -> String? {
        let day = stationDay(station)
        if station.kind == .apply { return deck.pending ? "待投递" : md(station.start) }
        if isLast, let ended = deck.ended {
            let word = ["rejected": "没通过", "accepted": "已接受", "withdrew": "我不继续了", "declined": "已婉拒"][ended.kind.rawValue] ?? "已结束"
            return "\(md(day)) · \(word)"
        }
        if !station.current {
            return station.result == "rejected" ? "\(md(day)) · 没通过" : station.result == "passed" ? "\(md(day)) · 通过" : md(day)
        }
        if station.kind == .screening {
            let waited = CareerDeckFormat.dayCount(station.start, now)
            return waited > 0 ? "已等 \(waited) 天" : "今天投递"
        }
        if station.kind == .oc { return "\(md(day)) · 等正式 Offer" }
        if station.kind == .offer { return "\(md(day)) · 待答复" }
        guard let session = live(station.session) else { return deck.stageState == "awaiting_schedule" ? "待安排" : "等结果" }
        if day > now {
            if session.text("schedule_kind") == "open_window" { return "\(md(day)) 前" }
            return "\(md(day)) · \(relativeDay(day, now: now) ?? CareerDeckFormat.weekday(day))"
        }
        return relativeDay(day, now: now) == "今天" ? "\(md(day)) · 今天" : "\(md(day)) · 等结果"
    }

    static func futureLabels(_ deck: CareerDeck, now: Date) -> [String] {
        guard deck.ended == nil else { return [] }
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        switch current.kind {
        case .apply: return ["筛选", "笔试 / 测评", "面试", "Offer"]
        case .screening: return ["笔试 / 测评", "面试", "Offer"]
        case .written: return ["面试", "Offer"]
        case .interview:
            guard let session = current.session else { return ["Offer"] }
            let done = session.text("status") == "completed" || (CareerApplication.date(session.text("end_at")).map { $0 < now } ?? false)
            return done ? ["下一面", "Offer"] : ["Offer"]
        case .oc: return ["Offer"]
        case .offer: return []
        }
    }

    public static func timeline(application app: JSONValue, deck: CareerDeck, now: Date) -> Timeline {
        let lastIndex = deck.stations.count - 1
        let stationOf = { (node: Node) in deck.stations.first { $0.id == node.stationID } }
        var nodes: [Node] = deck.stations.enumerated().map { index, station in
            let failed = station.result == "rejected" || (index == lastIndex && deck.ended?.kind == .rejected)
            let missed = missedCount(station.session)
            var line = nodeLine(station, deck: deck, now: now, isLast: index == lastIndex)
            if station.kind == .apply && !deck.pending {
                let channel = CareerDeck.source(app)
                line = channel.map { $0.count <= 4 ? "\(md(station.start)) · \($0)" : md(station.start) } ?? md(station.start)
            }
            return Node(id: station.id, label: station.kind == .apply && deck.pending ? "投递" : station.short, line: line,
                        note: missed > 0 ? "\(missed) 题没答到位" : nil,
                        kind: failed ? .failed : station.current && deck.ended == nil ? .current : .past,
                        stationID: station.id, day: station.kind == .apply && deck.pending ? nil : stationDay(station))
        }
        for label in futureLabels(deck, now: now) {
            nodes.append(Node(id: "future-" + label, label: label, line: nil, note: nil, kind: .future, stationID: nil, day: nil))
        }
        let head = deck.ended != nil ? "共 \(deck.days) 天" : deck.pending ? "导入 \(deck.days) 天，还没投递"
            : deck.days > 0 ? "从投递到现在 · \(deck.days) 天" : "今天投递"

        // 「今天」是蓝线走到的地方：约好还没到，按天数落在通往这一轮的那段上；已经面完 / 做完在等结果，
        // 落在这一轮之后那段的正中；就是今天时节点自己变成今天的点。筛选这类没有场次的阶段不画
        var today: Today?
        var todayNode: String?
        let currentIndex = nodes.firstIndex { $0.kind == .current }
        if let currentIndex, currentIndex > 0, deck.ended == nil {
            let node = nodes[currentIndex], before = nodes[currentIndex - 1]
            let hasSession = stationOf(node)?.session != nil
            let isToday = relativeDay(node.day ?? now, now: now) == "今天"
            if hasSession && node.day != nil && isToday {
                todayNode = node.id
            } else if let day = node.day, let start = before.day, day > now {
                let total = day.timeIntervalSince(start)
                let ratio = total > 0 ? min(0.8, max(0.2, now.timeIntervalSince(start) / total)) : 0.5
                // 实线太短时写不下天数
                today = Today(segment: currentIndex - 1, ratio: ratio, days: ratio >= 0.45 ? CareerDeckFormat.dayCount(start, now) : nil)
            } else if hasSession && currentIndex < nodes.count - 1 && !isToday {
                today = Today(segment: currentIndex, ratio: 0.5, days: node.day.map { CareerDeckFormat.dayCount($0, now) })
            }
        }
        let waiting = today != nil && today?.segment == currentIndex

        var segments: [Segment] = []
        for index in nodes.indices.dropLast() {
            let node = nodes[index], next = nodes[index + 1]
            let screeningNow = next.kind == .current && stationOf(next)?.kind == .screening
            let days: Int? = next.kind == .future ? nil : node.day.flatMap { from in (screeningNow ? now : next.day).map { CareerDeckFormat.dayCount(from, $0) } }
            let style: Segment.Style = next.kind == .future ? .future : next.kind == .current && !waiting ? .current : .past
            segments.append(Segment(style: style, days: days.flatMap { $0 > 0 ? $0 : nil }))
        }
        return Timeline(head: head, nodes: nodes, segments: segments, today: today, todayNode: todayNode)
    }
}
