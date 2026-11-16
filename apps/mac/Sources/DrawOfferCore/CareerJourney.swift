import Foundation

/// 投递详情（Figma 07 页 04–09 分区）的文案与状态，对应 Web `features/interviews/progress/journey.tsx`：
/// 上半讲“这一步”——眉题（公司 · 岗位 + 蓝色阶段）、衬线结论标题、一句说明、一个随状态变的黑按钮 + 白色「有新进展」；
/// 右侧随状态换内容；底部是全程时间线。这里只算文案，画法在 App 的 `CareerJourneyViews`。
public enum CareerJourneyAction: String, Sendable {
    case recordApplied, openSource, advance, schedule, reschedule, enter, mock
    case generateReview, openReview, openRecord, openWritten, recordOffer, decide, editOffer, reopen, backToNow
}

public struct CareerJourneyButton: Sendable, Equatable {
    public let action: CareerJourneyAction
    public let label: String
    public init(_ action: CareerJourneyAction, _ label: String) { self.action = action; self.label = label }
}

/// 右侧随状态放的那一样东西（04 分区「说明 · 右侧随状态」）。
public enum CareerJourneySide: String, Sendable { case resume, prep, recordEntry, questions, review, written, offer, oc, left, none }

public struct CareerJourneyPlace: Sendable, Equatable {
    public let text: String
    public let copy: String
    public let url: URL?
    /// 末尾带「· 修改安排」。
    public let editable: Bool
}

public struct CareerJourneyStep: Sendable {
    public let stage: String
    public let title: String
    public let desc: String?
    public let place: CareerJourneyPlace?
    public let primary: CareerJourneyButton?
    public let secondary: CareerJourneyButton?
    public let side: CareerJourneySide
}

public enum CareerJourney {
    // MARK: 小工具

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
        value >= 1 && value <= 9 ? String(Array("一二三四五六七八九")[value - 1]) : String(value)
    }

    static func interviewCount(_ deck: CareerDeck) -> Int {
        deck.stations.filter { $0.kind == .interview && live($0.session) != nil }.count
    }

    static func sourceURL(_ app: JSONValue) -> URL? {
        let value = app["job_snapshot"]?.text("source_url") ?? ""
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }

    // MARK: 复盘结论（和报告页同一套判定，含用户改过的层）

    struct GraphQuestion { let key: String; let kind: String; let title: String; let topic: String; let outcome: String; let answer: String }

    static func categoryLabel(_ value: String) -> String {
        ["technical": "技术题", "project": "项目题", "behavioral": "行为题", "hr": "HR 题"][value] ?? ""
    }

    /// Web `review/model.ts` 的 `outcomeOf`。
    static func outcome(_ question: JSONValue, userDepth: Int?) -> String {
        let kind = question.text("kind").nonEmptyValue ?? "main"
        if kind == "reverse" { return "not_judged" }
        if userDepth == nil, let value = question.text("outcome").nonEmptyValue { return value }
        if question.text("answer_status") == "missing" { return "unrecorded" }
        if question.text("answer_status") == "declined" && userDepth == nil { return "missed" }
        let layered: Bool = { if case .bool(let value) = question["depth_scored"] ?? .null { return value }; return !["hr", "behavioral"].contains(question.text("category")) }()
        if !layered && userDepth == nil {
            let verdicts = (question["signals"]?.items ?? []).map { $0.text("verdict") }.filter { $0 != "not_probed" }
            guard !verdicts.isEmpty else { return "unrecorded" }
            let share = verdicts.reduce(0.0) { $0 + ($1 == "hit" ? 1 : $1 == "partial" ? 0.5 : 0) } / Double(verdicts.count)
            return share >= 0.67 ? "reached" : share >= 0.34 ? "one_short" : "missed"
        }
        guard let depth = userDepth ?? question["achieved_depth"]?.numberValue.map({ Int($0) }) else { return "unrecorded" }
        let target = question["target_depth"]?.numberValue.map { Int($0) } ?? question["expected_depth"]?.numberValue.map { Int($0) } ?? 3
        let gap = target - depth
        return gap <= 0 ? "reached" : gap == 1 ? "one_short" : "missed"
    }

    static func graph(_ session: JSONValue) -> [GraphQuestion]? {
        let report = session["review_report"] ?? .null
        guard CareerReview.isV2(report) else { return nil }
        var notes: [String: Int] = [:]
        for note in session["review_question_notes"]?.items ?? [] {
            if let depth = note["user_depth"]?.numberValue { notes[note.text("question_key")] = Int(depth) }
        }
        return (report["questions"]?.items ?? []).map { source in
            let kind = source.text("kind").nonEmptyValue ?? "main"
            let raw = source.text("question").trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = raw.replacingOccurrences(of: "[？?。.！!]+$", with: "", options: .regularExpression)
            let short = clean.count > 10 ? String(clean.prefix(10)) + "…" : clean
            return GraphQuestion(key: source.text("key"), kind: kind,
                                 title: kind == "reverse" ? "反问" : source.text("title").trimmingCharacters(in: .whitespaces).nonEmptyValue ?? short,
                                 topic: kind == "reverse" ? "反问" : source.text("topic").trimmingCharacters(in: .whitespaces).nonEmptyValue ?? categoryLabel(source.text("category")),
                                 outcome: outcome(source, userDepth: notes[source.text("key")]),
                                 answer: source.text("answer"))
        }
    }

    public struct WeakPoint: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let quote: String?
    }

    /// 复盘里没答到位的几处：只算没答上和差一层。
    public static func weakPoints(_ session: JSONValue?, stageShort: String? = nil) -> [WeakPoint] {
        guard let session, let questions = graph(session) else { return [] }
        return questions.filter { $0.kind != "reverse" && ($0.outcome == "missed" || $0.outcome == "one_short") }.map { item in
            let missed = item.outcome == "missed"
            let answer = item.answer.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let what = missed ? "没答上" : "差一层"
            let topic: String? = item.topic.isEmpty ? nil : item.topic.unicodeScalars.first.map { $0.isASCII } == true ? "属于 \(item.topic)" : "属于\(item.topic)"
            let clip = answer.count > 24 ? String(answer.prefix(24)) + "…" : answer
            return WeakPoint(id: item.key, title: item.title.count > 16 ? String(item.title.prefix(16)) + "…" : item.title,
                             detail: [topic, stageShort.map { $0 + what } ?? what].compactMap { $0 }.joined(separator: " · "),
                             quote: answer.isEmpty ? nil : missed ? "你停在“\(clip)”" : "你只说了“\(clip)”")
        }
    }

    public static func missedCount(_ session: JSONValue?) -> Int { weakPoints(session).count }

    /// Web `ReviewBand.reviewHeadline(...).detail`：差一层 / 答到位 / 没记下各几题。
    public static func reviewDetail(_ session: JSONValue) -> String {
        guard let questions = graph(session) else { return "点开看每道题的分析" }
        let marks = questions.map { $0.outcome == "reached" ? "good" : $0.outcome == "one_short" ? "shallow" : $0.outcome == "missed" ? "missed" : "unrecorded" }
        let count = { (kind: String) in marks.filter { $0 == kind }.count }
        let parts = [
            count("shallow") > 0 && marks.contains("missed") ? "差一层 \(count("shallow"))" : nil,
            count("good") > 0 ? "答到位 \(count("good"))" : nil,
            count("unrecorded") > 0 ? "没记下 \(count("unrecorded"))" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return parts.isEmpty ? (session["review_report"]?.text("headline") ?? "") : parts
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

    /// 「22K × 15」。
    public static func offerSalary(_ app: JSONValue) -> String? {
        guard let salary = money(app.display("offer_salary")) else { return nil }
        return salary + (offerMonths(app).map { " × \($0)" } ?? "")
    }

    /// 「年包约 33 万」/「年薪」。
    public static func offerYearly(_ app: JSONValue) -> String? {
        let raw = app.display("offer_salary")
        if !raw.isEmpty, app.text("offer_salary_period") != "year", let months = offerMonths(app), let amount = Double(raw) {
            let value = (amount * Double(months) / 1000).rounded() / 10
            return "年包约 \(value == value.rounded() ? String(Int(value)) : String(value)) 万"
        }
        return app.text("offer_salary_period") == "year" ? "年薪" : nil
    }

    public static func dotDate(_ raw: String) -> String? {
        guard let date = offerDate(raw) else { return nil }
        let parts = Beijing.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0).\(CareerDeckFormat.two(parts.month ?? 0)).\(CareerDeckFormat.two(parts.day ?? 0))"
    }

    // MARK: 这一步

    public static func step(application app: JSONValue, deck: CareerDeck, station: CareerStation, viewing: Bool, now: Date,
                            detail: JSONValue?, previous: CareerStation?, reviewCost: String?) -> CareerJourneyStep {
        let advance = CareerJourneyButton(.advance, "有新进展")
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        let backToNow = CareerJourneyButton(.backToNow, "回到" + (deck.pending ? "待投递" : current.short))
        let session = live(station.session)
        func placeOf(_ editable: Bool) -> CareerJourneyPlace? {
            guard let session else { return nil }
            let location = session.text("location"), meeting = session.text("meeting_url")
            if session.text("mode") == "onsite", !location.isEmpty {
                let query = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return CareerJourneyPlace(text: location, copy: location, url: URL(string: "https://uri.amap.com/search?keyword=\(query)"), editable: editable)
            }
            if !meeting.isEmpty {
                return CareerJourneyPlace(text: meeting.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression), copy: meeting, url: URL(string: meeting), editable: editable)
            }
            return nil
        }
        func make(_ stage: String, _ title: String, _ desc: String?, place: CareerJourneyPlace? = nil, primary: CareerJourneyButton? = nil, secondary: CareerJourneyButton? = nil, side: CareerJourneySide) -> CareerJourneyStep {
            CareerJourneyStep(stage: stage, title: title, desc: desc, place: place, primary: primary, secondary: secondary, side: side)
        }
        let anyReview = deck.stations.reversed().first { CareerDeck.hasReview($0.session) }?.session

        // 09 分区：已结束，结论直接说结果
        if let ended = deck.ended, !viewing {
            let last = deck.stations[deck.stations.count - 1]
            let interviews = interviewCount(deck)
            let walked = interviews > 0 ? "走了 \(deck.days) 天、\(cnCount(interviews))场面试" : "走了 \(deck.days) 天"
            let review = anyReview != nil ? CareerJourneyButton(.openReview, "查看复盘") : nil
            switch ended.kind {
            case .withdrew:
                return make("已结束", "\(last.short)之后，不继续了。", "\(md(ended.at)) 你结束了这条投递。想回来随时可以恢复，之前的记录和复盘都在。",
                            primary: CareerJourneyButton(.reopen, "恢复投递"), secondary: review, side: .left)
            case .accepted:
                let start = offerDate(app.text("offer_start_on"))
                let parts = start.map { Beijing.calendar.dateComponents([.year, .month], from: $0) }
                return make("已接受", parts.map { "Offer 接受了，\($0.year ?? 0) 年 \($0.month ?? 0) 月入职。" } ?? "Offer 接受了。",
                            "\(md(ended.at)) 接受的。\(walked)，记录和复盘都留着。", primary: review, side: .offer)
            case .declined:
                return make("已结束", "婉拒了这个 Offer。", "\(md(ended.at)) 婉拒的。\(walked)，记录和复盘都留着。", primary: review, side: .offer)
            case .rejected:
                return make("已结束", "\(last.short)没通过。", anyReview != nil ? "\(walked)。没答上的地方都留下来了，下次会先提醒你。" : "\(walked)。记录都留着，之后的投递还能参考。",
                            primary: review, side: .left)
            case .other:
                return make("已结束", "这条投递结束了。", "\(walked)。记录都留着。", primary: review, side: .left)
            }
        }

        // 04 分区：投递前与筛选
        if station.kind == .apply && deck.pending {
            let created = CareerApplication.date(app.text("created_at")) ?? now
            let days = CareerDeckFormat.dayCount(created, now)
            return make("待投递", "还没投，选一份简历投出去。", (days > 0 ? "\(md(created)) 导入，已经放了 \(days) 天。" : "今天导入的。") + "投完回来记一笔。",
                        primary: CareerJourneyButton(.recordApplied, "记录投递"), secondary: sourceURL(app) != nil ? CareerJourneyButton(.openSource, "去官网投递 ↗") : nil, side: .resume)
        }
        if station.kind == .apply {
            let channel = CareerDeck.source(app)
            let resume = app.text("resume_title_snapshot")
            return make("投递 · \(md(station.start))", channel.map { "\(md(station.start)) 在\($0)投出去。" } ?? "\(md(station.start)) 投出去。",
                        resume.isEmpty ? nil : "投的是「\(resume)」。", secondary: backToNow, side: .resume)
        }
        if station.kind == .screening {
            if station.current && !viewing {
                let days = CareerDeckFormat.dayCount(station.start, now)
                let channel = CareerDeck.source(app)
                return make("筛选中", days > 0 ? "投出去 \(days) 天了，等简历筛选。" : "今天投出去，等简历筛选。",
                            (channel.map { "\(md(station.start)) 在\($0)投的。" } ?? "") + "没消息不用急，收到笔试或面试通知时，点「有新进展」记一笔。",
                            primary: advance, side: .resume)
            }
            let failed = station.result == "rejected"
            return make("筛选 · " + (failed ? "没通过" : "已通过"), failed ? "简历筛选没通过。" : "简历筛选通过。",
                        station.end.map { "投出去 \(CareerDeckFormat.dayCount(station.start, $0)) 天后出结果。" }, secondary: backToNow, side: .resume)
        }

        // 09 分区：OC 与 Offer
        if station.kind == .oc {
            let at = CareerApplication.date(app.text("oc_communicated_at")) ?? station.start
            if station.current && !viewing {
                let contact = app.text("oc_contact").nonEmptyValue ?? "HR"
                return make("OC · 口头 Offer", "拿到口头 Offer，等正式的。", "\(contact) \(md(at))沟通的，正式 Offer 一般一到两周内发。收到后在这里记下。",
                            primary: CareerJourneyButton(.recordOffer, "记录正式 Offer"), side: .oc)
            }
            return make("OC · \(md(at))", "拿到口头 Offer。", "\(md(at)) 沟通，之后转成了正式 Offer。", secondary: backToNow, side: .oc)
        }
        if station.kind == .offer {
            guard app.text("offer_status") != "none" else {
                return make("Offer · 信息待补充", "收到 Offer，先把信息补上。", "薪资、入职和答复截止填进来，做决定时一眼看全。",
                            primary: CareerJourneyButton(.editOffer, "编辑 Offer 信息"), side: .offer)
            }
            let due = offerDate(app.text("offer_reply_due_on"))
            let left = due.map { CareerFormat.days(from: now, to: $0) }
            let title = left.map { $0 > 0 ? "Offer 还有 \($0) 天要答复。" : $0 == 0 ? "Offer 今天要答复。" : "Offer 已过答复截止。" } ?? "收到 Offer，还没填答复截止。"
            return make("Offer · 待答复", title, due.map { "\(md($0)) 前答复。接受之后，其他还在进行的投递不会自动结束。" } ?? "答复截止可以在 ⋯ 里的「编辑 Offer 信息」补上。",
                        primary: CareerJourneyButton(.decide, "做决定"), side: .offer)
        }

        // 05–08 分区：笔试 / 测评 / 面试
        let written = station.kind == .written
        let isNow = station.current && !viewing

        if isNow && session == nil && deck.stageState == "awaiting_schedule" {
            let waited = CareerDeckFormat.dayCount(station.start, now)
            let passed = previous?.kind == .interview ? previous : nil
            let desc = written ? "笔试通知一般会给一个作答时段。把时段和链接填进来，截止前会出现在面试日程里。"
                : (passed.map { "\($0.short) \(md(stationDay($0))) 通过" } ?? "\(md(station.start)) 收到通知") + (waited > 0 ? "，已经等了 \(waited) 天。" : "。") + "收到时间后填进来，时间线和面试日程会一起更新。"
            return make("\(station.short) · 待安排", written ? "收到\(station.short)，还没定时间。" : "\(station.short)，等对方约时间。", desc,
                        primary: CareerJourneyButton(.schedule, "安排时间"), secondary: advance, side: .prep)
        }

        if isNow, let session, session.text("status") == "scheduled", let end = CareerApplication.date(session.text("end_at")), end > now {
            let start = CareerApplication.date(session.text("start_at")) ?? end
            let meeting = !session.text("meeting_url").isEmpty
            if written || session.text("schedule_kind") == "open_window" {
                let left = CareerDeckFormat.remaining(end, now: now, prefix: "还剩")
                let minutes: Int? = session.text("schedule_kind") == "open_window" ? nil : max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
                let desc = [left.map { "作答窗口\($0)" }, minutes.map { "约 \($0) 分钟" }].compactMap { $0 }.joined(separator: "，") + "。做之前把右边几处过一遍。"
                return make("\(station.short) · 线上", "\(md(end)) \(endClock(end)) 前做完\(station.short)。", desc, place: placeOf(true),
                            primary: meeting ? CareerJourneyButton(.enter, "进入\(station.short)") : advance, secondary: meeting ? advance : nil, side: .prep)
            }
            let day = relativeDay(start, now: now)
            let today = day == "今天"
            let left = CareerDeckFormat.remaining(start, now: now)
            let prepLeft = (session["prep_items"]?.items ?? []).filter { $0["done"]?.bool != true }.count
            let prevWeak = previous.flatMap { $0.kind == .interview && missedCount($0.session) > 0 ? $0 : nil }
            let desc = today
                ? (left.map { "\($0)，" } ?? "") + (meeting ? "会议链接在下面。" : !session.text("location").isEmpty ? "地点在下面。" : "") + (prepLeft > 0 ? "准备清单还剩 \(prepLeft) 项没勾。" : "")
                : (left.map { "\($0)，" } ?? "") + (meeting ? "会议链接已经存好。" : "") + (prevWeak.map { "面试前练一场，重点放在\($0.short)没接住的地方。" } ?? "面试前可以先练一场。")
            return make("\(station.short) · \(modeLabel(session))", "\(day ?? "\(md(start)) \(CareerDeckFormat.weekday(start))") \(CareerDeckFormat.clock(start))，\(station.short)。", desc,
                        place: placeOf(true), primary: today && meeting ? CareerJourneyButton(.enter, "进入会议") : CareerJourneyButton(.mock, "模拟这场面试"),
                        secondary: advance, side: .prep)
        }

        if let session {
            let record = recordState(session, detail)
            let result = station.result == "rejected" ? "没通过" : "已通过"
            if written {
                let questions = detail?["session"]?["written_questions"]?.items ?? session["written_questions"]?.items ?? []
                if isNow {
                    return make("\(station.short) · 已做完", "\(station.short)做完了，等结果。",
                                questions.isEmpty ? "趁还记得，把题目记下来，之后能逐题标对错。" : "记了 \(questions.count) 道题，可以逐题标对错。", primary: advance, side: .written)
                }
                return make("\(station.short) · \(md(stationDay(station))) · \(result)", station.result == "rejected" ? "\(station.short)没通过。" : "\(station.short)通过了。",
                            questions.isEmpty ? nil : "记了 \(questions.count) 道题。", primary: questions.isEmpty ? nil : CareerJourneyButton(.openWritten, "查看\(station.short)题"),
                            secondary: backToNow, side: .written)
            }
            let reviewed = session.text("review_status") != "failed" && CareerDeck.hasReview(session)
            let missed = missedCount(session)
            if isNow {
                let stage = reviewed ? "\(station.short) · 已复盘" : "\(station.short) · 已面完"
                if reviewed {
                    return make(stage, missed > 0 ? "\(station.short)有 \(missed) 处没答到位。" : "\(station.short)每道题都答到了位。", reviewDetail(session),
                                place: placeOf(false), primary: CareerJourneyButton(.openReview, "查看复盘"), secondary: advance, side: .review)
                }
                if session.text("review_status") == "generating" {
                    return make(stage, "正在复盘\(station.short)。", "一般 1 分钟左右，好了这里会更新，可以先去做别的。", place: placeOf(false), secondary: advance, side: .questions)
                }
                if case .ready(let count, _) = record {
                    let failed = session.text("review_status") == "failed"
                    return make(stage, "记下 \(count) 道题，可以复盘了。", failed ? "上次没生成出来，可以再试一次。" : "复盘会逐题对照你的回答，标出哪里没答到位、该怎么补。",
                                place: placeOf(false), primary: CareerJourneyButton(.generateReview, [failed ? "再试一次" : "生成复盘", reviewCost].compactMap { $0 }.joined(separator: " · ")),
                                secondary: advance, side: .questions)
                }
                let transcribing: Bool = { if case .transcribing = record { return true }; return false }()
                return make(stage, "\(station.short)面完了，等结果。",
                            transcribing ? "录音正在转成文字，好了会按问题拆好。" : "趁还记得，把问了什么记下来。记下来才能复盘，下一轮前也知道该补哪里。",
                            place: placeOf(false), secondary: advance, side: .recordEntry)
            }
            // 07.08：回看过去的一轮
            let ready: Int? = { if case .ready(let count, _) = record { return count }; return nil }()
            let verb = station.result == "rejected" ? "没通过" : "通过"
            let title = reviewed
                ? (missed > 0 ? "\(station.short)\(verb)，\(missed) 处没答到位。" : "\(station.short)\(verb)，每道题都答到了位。")
                : (station.result == "rejected" ? "\(station.short)没通过。" : "\(station.short)通过了。")
            return make("\(station.short) · \(md(stationDay(station))) · \(result)", title,
                        reviewed ? reviewDetail(session) : ready.map { "记了 \($0) 道题，还没复盘。" } ?? "这一轮还没有面试记录。",
                        primary: reviewed ? CareerJourneyButton(.openReview, "查看复盘") : ready != nil ? CareerJourneyButton(.openRecord, "查看面试记录") : nil,
                        secondary: backToNow, side: reviewed ? .review : ready != nil ? .questions : .recordEntry)
        }

        if isNow {
            return make(station.short, "等\(station.short)的结果。", "这一轮没有记下时间。收到消息后，点「有新进展」记一笔。", primary: advance, side: .prep)
        }
        let failed = station.result == "rejected"
        return make("\(station.short) · " + (failed ? "没通过" : "已通过"), failed ? "\(station.short)没通过。" : "\(station.short)通过了。", "这一轮没有记下时间。",
                    secondary: backToNow, side: .none)
    }

    // MARK: 全程时间线（各分区底部）

    public struct Node: Identifiable, Sendable {
        public enum Kind: Sendable { case past, current, future, failed }
        public let id: String
        public let label: String
        public let line: String?
        /// 「3 处没答到位」，带橙点。
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

    public struct Timeline: Sendable {
        public let head: String
        public let nodes: [Node]
        public let segments: [Segment]
        /// 「今天」竖线落在第几段的哪个位置。
        public let today: (segment: Int, ratio: Double)?
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
        var nodes: [Node] = deck.stations.enumerated().map { index, station in
            let failed = station.result == "rejected" || (index == lastIndex && deck.ended?.kind == .rejected)
            let missed = missedCount(station.session)
            var line = nodeLine(station, deck: deck, now: now, isLast: index == lastIndex)
            if station.kind == .apply && !deck.pending {
                let channel = CareerDeck.source(app)
                line = channel.map { $0.count <= 4 ? "\(md(station.start)) · \($0)" : md(station.start) } ?? md(station.start)
            }
            return Node(id: station.id, label: station.kind == .apply && deck.pending ? "投递" : station.short, line: line,
                        note: missed > 0 ? "\(missed) 处没答到位" : nil,
                        kind: failed ? .failed : station.current && deck.ended == nil ? .current : .past,
                        stationID: station.id, day: station.kind == .apply && deck.pending ? nil : stationDay(station))
        }
        for label in futureLabels(deck, now: now) {
            nodes.append(Node(id: "future-" + label, label: label, line: nil, note: nil, kind: .future, stationID: nil, day: nil))
        }
        let head = deck.ended != nil ? "共 \(deck.days) 天" : deck.pending ? "导入 \(deck.days) 天，还没投递" : "从投递到现在 · \(deck.days) 天"

        var segments: [Segment] = []
        for index in nodes.indices.dropLast() {
            let node = nodes[index], next = nodes[index + 1]
            let screeningNow = next.kind == .current && deck.stations.first { $0.id == next.stationID }?.kind == .screening
            let days: Int? = next.kind == .future ? nil : node.day.flatMap { from in (screeningNow ? now : next.day).map { CareerDeckFormat.dayCount(from, $0) } }
            segments.append(Segment(style: next.kind == .future ? .future : next.kind == .current ? .current : .past, days: days.flatMap { $0 > 0 ? $0 : nil }))
        }

        // 「今天」：当前节点在未来时画在它前面那段，已面完在等结果时贴在它后面那段
        var today: (Int, Double)?
        if let currentIndex = nodes.firstIndex(where: { $0.kind == .current }), currentIndex > 0, deck.ended == nil {
            let node = nodes[currentIndex], before = nodes[currentIndex - 1]
            if let day = node.day, let start = before.day, day > now {
                let total = day.timeIntervalSince(start)
                today = (currentIndex - 1, total > 0 ? min(0.88, max(0.12, now.timeIntervalSince(start) / total)) : 0.5)
            } else if let station = deck.stations.first(where: { $0.id == node.stationID }), station.session != nil, currentIndex < nodes.count - 1,
                      relativeDay(node.day ?? now, now: now) != "今天" {
                today = (currentIndex, 0.16)
            }
        }
        return Timeline(head: head, nodes: nodes, segments: segments, today: today.map { (segment: $0.0, ratio: $0.1) })
    }

    // MARK: 右侧：面试中问到（07.06）

    public struct TopicCard: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let meta: String
        public let quote: String
        /// 这题在完整记录里的位置，用来打开记录。
        public let position: Int
        public let many: Bool
    }

    static func positionsText(_ positions: [Int]) -> String {
        var parts: [String] = []
        var start = 0
        while start < positions.count {
            var end = start
            while end + 1 < positions.count && positions[end + 1] == positions[end] + 1 { end += 1 }
            if end - start >= 2 { parts.append("\(positions[start])–\(positions[end])") }
            else { for index in start...end { parts.append(String(positions[index])) } }
            start = end + 1
        }
        return parts.joined(separator: "、")
    }

    /// 反问不算考点；按考点归组列原话，不下判断；考点还没整理好时先按题列。最多三张。
    public static func topicCards(_ questions: [RecordQuestion], groups: [JSONValue]?) -> [TopicCard] {
        let mains = questions.enumerated().filter { $0.element.reply == nil && $0.element.question.trimmingCharacters(in: .whitespaces).range(of: "^反问[：:]", options: .regularExpression) == nil }
        let generic = "自我介绍|介绍一下(你)?自己|求职动机|为什么(选择|想来|投递|离职)|离职原因|职业规划"
        let quote = { (text: String) in "“\(text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? "（没记下问题）")”" }
        var cards: [(card: TopicCard, generic: Bool)] = []
        if let groups {
            for group in groups {
                let members = (group["questions"]?.items ?? []).compactMap { $0.numberValue.map { Int($0) } }.compactMap { $0 >= 1 && $0 <= mains.count ? mains[$0 - 1] : nil }
                guard let first = members.first else { continue }
                let numbers = members.map { $0.offset + 1 }
                let topic = group.text("topic").nonEmptyValue
                let text = first.element.question.trimmingCharacters(in: .whitespacesAndNewlines)
                let many = members.count > 1
                cards.append((TopicCard(id: (topic ?? "") + "-\(numbers[0])",
                                        title: topic ?? (text.count > 16 ? String(text.prefix(16)) + "…" : text.nonEmptyValue ?? "第 \(numbers[0]) 题"),
                                        meta: many ? "问了 \(members.count) 题 · 第 \(positionsText(numbers)) 题" : "第 \(numbers[0]) 题",
                                        quote: quote(first.element.question), position: first.offset, many: many),
                              "\(topic ?? "") \(first.element.question)".range(of: generic, options: .regularExpression) != nil))
            }
        } else {
            for (position, item) in mains {
                cards.append((TopicCard(id: String(position), title: "第 \(position + 1) 题",
                                        meta: item.followUps.isEmpty ? "没有追问" : "被追问了 \(item.followUps.count) 次",
                                        quote: quote(item.question), position: position, many: false),
                              item.question.range(of: generic, options: .regularExpression) != nil))
            }
        }
        let ordered = cards.filter { $0.card.many } + cards.filter { !$0.card.many && !$0.generic } + cards.filter { !$0.card.many && $0.generic }
        return ordered.prefix(3).map(\.card).sorted { $0.position < $1.position }
    }

    /// 送去整理考点的题目（反问除外，最多 60 题）。
    public static func topicQuestions(_ questions: [RecordQuestion]) -> [String] {
        questions.filter { $0.reply == nil && $0.question.trimmingCharacters(in: .whitespaces).range(of: "^反问[：:]", options: .regularExpression) == nil }
            .prefix(60).map { String($0.question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)).nonEmptyValue ?? "（没记下问题）" }
    }
}
