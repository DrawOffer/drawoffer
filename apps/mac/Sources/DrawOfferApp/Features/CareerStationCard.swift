import DrawOfferCore
import SwiftUI

/// 站点详情里的动作，对应 Web `StationCard` 的 `DeckAction`；由 `CareerApplicationDetailView` 接到现有弹窗。
enum CareerDeckAction {
    case recordApplied, advance, schedule, reschedule, recordOffer, editOffer, handleOffer, editJob, editDelivery, reopen, reject
    case materials(String), allMaterials, review(JSONValue?), generateReview(JSONValue), prepToggle(JSONValue, Int), prepGenerate(JSONValue), prepOpen(JSONValue), copy(String), uploadOffer
}

/// Web `features/interviews/progress/StationCard.tsx`：上半是日历页、标题、说明和右下的操作，下半是三张缩略图。
/// 内容按站点种类与「做之前 / 做之后」分开，文案与 Web 一致。
struct CareerStationCard: View {
    let application: JSONValue
    let deck: CareerDeck
    let station: CareerStation
    let previous: CareerStation?
    let details: [String: JSONValue]
    let viewing: Bool
    let now: Date
    let busy: Bool
    let prepBusy: Bool
    let materialsCount: Int
    let act: (CareerDeckAction) -> Void

    private struct Hero {
        var day: Date
        var title: String
        var sub: String?
        var note: String?
        var tone: String?
        var place: JSONValue?
    }
    private struct Action { let label: String; var kind: PDButtonStyle.Kind = .normal; var disabled = false; let run: CareerDeckAction }

    var body: some View {
        let content = build()
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 46) {
                CareerCalendarPage(date: content.hero.day, tone: content.hero.tone).frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text("第 \(station.index) 站 · \(content.title)").font(V3.sans(14)).foregroundStyle(PD.mute)
                        if !content.status.isEmpty {
                            let color = content.statusTone == "red" ? PD.red : content.statusTone == "gray" ? Color(hex: 0x6F6F69) : PD.blueText
                            HStack(spacing: 5) {
                                Circle().fill(content.statusTone == "red" ? PD.red : content.statusTone == "gray" ? PD.mute : PD.blue).frame(width: 6, height: 6)
                                Text(content.status).font(V3.sans(12.5, weight: .medium))
                            }.foregroundStyle(color)
                        }
                    }.frame(height: 20)
                    Text(content.hero.title).font(V3.sans(34, weight: .medium)).kerning(-0.34).foregroundStyle(PD.ink)
                        .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44).padding(.top, 8)
                    if let sub = content.hero.sub, !sub.isEmpty { Text(sub).font(V3.sans(15)).foregroundStyle(PD.body).frame(minHeight: 22).padding(.top, 10) }
                    if let note = content.hero.note, !note.isEmpty { Text(note).font(V3.sans(14)).foregroundStyle(PD.mute).frame(minHeight: 21).padding(.top, 4) }
                    if let session = content.hero.place { place(session) }
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        ForEach(Array(content.actions.enumerated()), id: \.offset) { _, action in
                            Button(action.label) { act(action.run) }.buttonStyle(PDButtonStyle(kind: action.kind)).disabled(action.disabled)
                        }
                    }.padding(.top, 26)
                }
                .padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
            CareerThumbShelf(title: content.shelfTitle, items: content.shelf, all: { act(.allMaterials) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第 \(station.index) 站：\(station.title)")
    }

    private func place(_ session: JSONValue) -> some View {
        let onsite = session.text("mode") == "onsite" && !session.text("location").isEmpty
        let text = onsite ? session.text("location") : session.text("meeting_url").replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        let link = onsite ? "https://uri.amap.com/search?keyword=" + (session.text("location").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") : session.text("meeting_url")
        return HStack(spacing: 8) {
            Image(systemName: onsite ? "mappin.and.ellipse" : "link").font(.system(size: 13)).foregroundStyle(PD.mute)
            Text(text).font(V3.sans(14)).foregroundStyle(PD.body).lineLimit(1)
            Button("复制") { act(.copy(onsite ? session.text("location") : session.text("meeting_url"))) }.buttonStyle(.plain).font(V3.sans(14)).foregroundStyle(PD.ink)
            if let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") {
                Link(onsite ? "地图 ↗" : "打开 ↗", destination: url).font(V3.sans(13, weight: .medium)).foregroundStyle(PD.ink)
            }
        }.frame(height: 20).padding(.top, 10)
    }

    // MARK: 内容

    private struct Content {
        var title: String
        var status = ""
        var statusTone: String?
        var hero: Hero
        var shelfTitle: String
        var shelf: [CareerThumb]
        var actions: [Action]
    }

    private func md(_ date: Date?) -> String { CareerDeckFormat.monthDay(date) }
    private func clock(_ date: Date) -> String { CareerDeckFormat.clock(date) }
    private func dayLabel(_ date: Date) -> String { "\(md(date)) \(CareerDeckFormat.weekday(date))" }
    private func waited(_ days: Int) -> String? { days > 0 ? "已等 \(days) 天" : nil }
    private func relativeDay(_ date: Date) -> String {
        switch CareerFormat.days(from: now, to: date) {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: return dayLabel(date)
        }
    }
    private func endClock(_ date: Date) -> String { let text = clock(date); return text == "00:00" ? "24:00" : text }
    private func date(_ value: JSONValue?, _ field: String) -> Date? { value.flatMap { CareerApplication.date($0.text(field)) } }
    private func minutes(_ session: JSONValue) -> Int {
        guard let s = date(session, "start_at"), let e = date(session, "end_at") else { return 1 }
        return max(1, Int((e.timeIntervalSince(s) / 60).rounded()))
    }
    private func detail(_ session: JSONValue?) -> JSONValue? { session.flatMap { details[$0.text("id")] } }
    private func dotDate(_ raw: String) -> String? {
        guard let value = CareerFormat.offerDate(raw) else { return nil }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: value)
        return "\(parts.year ?? 0).\(CareerDeckFormat.two(parts.month ?? 0)).\(CareerDeckFormat.two(parts.day ?? 0))"
    }
    private func money(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard let amount = Double(raw) else { return raw }
        return amount >= 1000 && amount.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(amount / 1000))K" : String(Int(amount))
    }

    private func questions(_ session: JSONValue) -> [String] {
        let markdown = detail(session)?["session"]?.text("questions_markdown").nonEmptyValue ?? session.text("questions_markdown")
        return InterviewRecord.parse(markdown).map { $0.question.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? "（没记下问题）" }
    }
    private func reviewHeadline(_ session: JSONValue) -> String? {
        let report = session["review_report"] ?? .null
        if report["schema_version"]?.integer == 2 { return report.text("headline").nonEmptyValue ?? report.text("summary").nonEmptyValue }
        return report.text("summary").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue ?? session.text("review_summary").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue
    }
    private func reviewGaps(_ session: JSONValue) -> [String] {
        let report = session["review_report"] ?? .null
        if report["schema_version"]?.integer == 2 {
            let items = (report["improvements"]?.items ?? []).map { $0.text("title") }.filter { !$0.isEmpty }
            return Array((items.isEmpty ? (report["questions"]?.items ?? []).map { $0.text("improvement") }.filter { !$0.isEmpty } : items).prefix(3))
        }
        return Array((report["questions"]?.items ?? []).map { $0.text("improvement") }.filter { !$0.isEmpty }.prefix(3))
    }
    private func jobSkills() -> [String] {
        let snapshot = application["job_snapshot"] ?? .null
        let skills = (snapshot["skills"]?.items ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces).nonEmptyValue }
        if !skills.isEmpty { return Array(skills.prefix(3)) }
        let description = snapshot.text("description")
        return Array(description.components(separatedBy: CharacterSet(charactersIn: "\n；;。"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t0123456789.、-*·")) }
            .filter { !$0.isEmpty }.prefix(3))
    }

    // MARK: 缩略图

    private func info(_ id: String, _ name: String, _ rows: [(String, String?)], meta: String? = nil, open: CareerDeckAction? = nil) -> CareerThumb {
        CareerThumb(id: id, name: name, meta: meta, preview: .info(rows.map { ($0.0, $0.1?.nonEmptyValue) }), open: open.map { action in { act(action) } })
    }
    private func resumeThumb(pending: Bool = false) -> CareerThumb {
        let title = application.text("resume_title_snapshot").nonEmptyValue
        return CareerThumb(id: "resume", name: "投递简历", meta: title ?? (pending ? "投递时选择" : "没有关联"),
                           preview: title.map { CareerThumb.Preview.doc($0, [88, 64, 76, 52]) } ?? .empty(icon: "paperclip", text: pending ? "投递时再选简历" : "还没有关联投递简历", actions: pending ? [] : [("选简历", { act(.editDelivery) })]),
                           open: title == nil ? nil : { act(.editDelivery) })
    }
    private func jobThumb() -> CareerThumb {
        let skills = jobSkills(), hasJob = !application.text("job_description_id").isEmpty
        return CareerThumb(id: "job", name: "岗位要求", meta: skills.isEmpty ? "没填岗位信息" : "来自岗位信息",
                           preview: skills.isEmpty ? .empty(icon: "list.bullet", text: "补上岗位要求，准备和复盘会更准", actions: hasJob ? [("补充", { act(.editJob) })] : []) : .list(kicker: nil, items: skills),
                           open: !skills.isEmpty && hasJob ? { act(.editJob) } : nil)
    }
    private func filesThumb(_ session: JSONValue) -> CareerThumb {
        let assets = detail(session)?["assets"]?.items ?? []
        let id = session.text("id")
        return CareerThumb(id: "files", name: "资料", meta: "\(assets.count) 份",
                           preview: assets.isEmpty ? .empty(icon: "paperclip", text: "面经、公司资料都可以放这里", actions: [("添加资料", { act(.materials(id)) })])
                           : .files(assets.prefix(2).map { $0.text("original_file_name") }, more: max(0, assets.count - 2)),
                           open: assets.isEmpty ? nil : { act(.materials(id)) })
    }
    private func prepThumb(_ session: JSONValue) -> CareerThumb {
        let items = session["prep_items"]?.items ?? []
        if items.isEmpty {
            let canGenerate = (session["prep_generated_at"] ?? .null) == .null
            return CareerThumb(id: "prep", name: "准备清单", meta: prepBusy ? "生成中…" : "还没有",
                               preview: prepBusy ? .doc("", [80, 64, 72]) : .empty(icon: "list.bullet", text: canGenerate ? "按岗位要求和你的简历生成" : "自己列几条要准备的",
                                                                                 actions: [canGenerate ? ("生成清单", { act(.prepGenerate(session)) }) : ("+ 添加", { act(.prepOpen(session)) })]))
        }
        let done = items.filter { $0["done"]?.bool == true }.count
        return CareerThumb(id: "prep", name: "准备清单", meta: "完成 \(done) / \(items.count)",
                           preview: .checks(items.prefix(3).enumerated().map { index, item in (item.text("title"), item["done"]?.bool == true, { act(.prepToggle(session, index)) }) }), open: { act(.prepOpen(session)) })
    }
    private func weakThumb(_ previous: CareerStation) -> CareerThumb? {
        guard let session = previous.session, CareerDeck.hasReview(session) else { return nil }
        let gaps = reviewGaps(session)
        return CareerThumb(id: "weak", name: "上一面要补的", meta: "来自\(previous.short)复盘",
                           preview: gaps.isEmpty ? .text(kicker: "\(previous.short)复盘", text: reviewHeadline(session) ?? "没有要补的", strong: false) : .list(kicker: "\(previous.short)复盘 · 待加强", items: gaps),
                           open: { act(.review(session)) })
    }
    private func previousRecordThumb(_ previous: CareerStation) -> CareerThumb? {
        guard let session = previous.session else { return nil }
        let list = questions(session)
        guard !list.isEmpty else { return nil }
        return CareerThumb(id: "prev-record", name: "\(previous.short)面试记录", meta: "\(list.count) 道题", preview: .qa(list), open: { act(.materials(session.text("id"))) })
    }
    private func recordThumb(_ session: JSONValue) -> CareerThumb {
        let id = session.text("id"), list = questions(session)
        if !list.isEmpty {
            return CareerThumb(id: "record", name: "面试记录", meta: "\(list.count) 道题 · " + (session.text("transcript_source") == "transcription" ? "录音转写" : "文字整理"), preview: .qa(list), open: { act(.materials(id)) })
        }
        let transcriptions = detail(session)?["session"]?["transcriptions"]?.items ?? session["transcriptions"]?.items ?? []
        if transcriptions.contains(where: { ["queued", "running"].contains($0.text("status")) }) {
            return CareerThumb(id: "record", name: "面试记录", meta: "转写中", preview: .text(kicker: nil, text: "正在转成文字", strong: false))
        }
        if transcriptions.contains(where: { $0.text("status") == "failed" }) {
            return CareerThumb(id: "record", name: "面试记录", meta: "没能整理出来", preview: .empty(icon: "mic", text: "录音没能转成文字", actions: [("重新上传", { act(.materials(id)) }), ("粘贴文字", { act(.materials(id)) })]))
        }
        return CareerThumb(id: "record", name: "面试记录", meta: "还没有", preview: .empty(icon: "mic", text: "上传录音，或粘贴自己记的内容", actions: [("上传录音", { act(.materials(id)) }), ("粘贴文字", { act(.materials(id)) })]))
    }
    private func reviewThumb(_ session: JSONValue) -> CareerThumb {
        if session.text("review_status") == "generating" {
            return CareerThumb(id: "review", name: "复盘", meta: "正在复盘", preview: .text(kicker: nil, text: "正在逐题看你的回答…", strong: false), open: { act(.review(session)) })
        }
        if session.text("review_status") != "failed" && CareerDeck.hasReview(session) {
            let gaps = reviewGaps(session)
            return CareerThumb(id: "review", name: "复盘", meta: "已生成",
                               preview: gaps.isEmpty ? .text(kicker: nil, text: reviewHeadline(session) ?? "复盘已生成", strong: true) : .list(kicker: reviewHeadline(session) ?? "待加强", items: Array(gaps.prefix(2))),
                               open: { act(.review(session)) })
        }
        let count = questions(session).count
        if count > 0 {
            let failed = session.text("review_status") == "failed"
            return CareerThumb(id: "review", name: "复盘", meta: failed ? "没生成出来" : "可以生成",
                               preview: .empty(icon: "sparkle", text: failed ? "上次没生成出来，可以再试一次" : "按 \(count) 道题的问答，看哪些答得好、哪些要补", actions: [(failed ? "再试一次" : "生成复盘", { act(.generateReview(session)) })]))
        }
        return CareerThumb(id: "review", name: "复盘", meta: "等面试记录", preview: .empty(icon: "sparkle", text: "有了面试记录就能生成复盘", actions: []))
    }
    private func writtenThumb(_ session: JSONValue) -> CareerThumb {
        let items = detail(session)?["session"]?["written_questions"]?.items ?? session["written_questions"]?.items ?? []
        let id = session.text("id")
        if items.isEmpty { return CareerThumb(id: "written", name: "笔试题", meta: "还没有", preview: .empty(icon: "square.and.arrow.up", text: "上传题目截图或文档，整理成题目", actions: [("添加笔试题", { act(.materials(id)) })])) }
        let correct = items.filter { $0.text("correctness") == "correct" }.count
        return CareerThumb(id: "written", name: "笔试题", meta: "\(items.count) 道 · 答对 \(correct)",
                           preview: .written(items.prefix(3).map { ($0.display("question_no"), $0.text("question_text"), $0.text("correctness")) }), open: { act(.materials(id)) })
    }

    // MARK: 按站点组装

    private func build() -> Content {
        let session = station.session
        let written = station.kind == .written
        let canReject = application.text("offer_status") == "none"
        let reject = canReject ? [Action(label: "没通过", kind: .reject, disabled: busy, run: .reject)] : []
        let isLast = deck.stations.last?.id == station.id
        let ended = !viewing && !station.current && isLast ? deck.ended : nil
        let source = CareerDeck.source(application)
        func fromPrevious() -> [CareerThumb] {
            guard let previous, previous.kind == .interview else { return [] }
            return [weakThumb(previous), previousRecordThumb(previous)].compactMap { $0 }
        }

        if let ended {
            let reviewed = deck.stations.filter { CareerDeck.hasReview($0.session) }
            let copy: (String, String, String?, String) = switch ended.kind {
            case .rejected: ("没通过", "没通过", "red", "记录会一直保留，复盘可以在之后的投递里继续参考。")
            case .accepted: ("已接受", "接受了 Offer", nil, "这条投递完成了。记录会一直保留，复盘可以在之后的求职里参考。")
            case .withdrew: ("我不继续了", "我不继续了", "gray", "你在 \(md(ended.at)) 主动结束了这条投递。记录会保留，想继续可以恢复。")
            case .declined: ("已婉拒", "婉拒了 Offer", "gray", "你婉拒了这个 Offer，记录会一直保留。")
            case .other: ("已结束", "已结束", "gray", "这条投递已经结束，记录会一直保留。")
            }
            let lastSession = deck.stations.reversed().compactMap(\.session).first
            let latestReview = reviewed.last?.session
            var actions: [Action] = []
            if ended.kind == .withdrew { actions.append(Action(label: "恢复投递", disabled: busy, run: .reopen)) }
            if ended.kind == .accepted { actions.append(Action(label: "查看 Offer", run: .editOffer)) }
            if [.rejected, .other, .declined].contains(ended.kind), let lastSession { actions.append(Action(label: "编辑记录", run: .materials(lastSession.text("id")))) }
            actions.append(Action(label: "查看复盘", kind: .primary, disabled: reviewed.isEmpty, run: .review(latestReview)))
            return Content(
                title: deck.stations.last?.title ?? station.title, status: copy.0, statusTone: copy.2,
                hero: Hero(day: ended.at, title: copy.1, sub: "\(dayLabel(ended.at)) 结束 · 走了 \(deck.stations.count) 站 · \(deck.days) 天", note: copy.3, tone: ended.kind == .rejected ? "red" : ended.kind == .accepted ? nil : "gray"),
                shelfTitle: "这条投递留下的",
                shelf: [
                    latestReview.map { review in CareerThumb(id: "reviews", name: "复盘", meta: "\(reviewed.count) 篇", preview: .text(kicker: nil, text: reviewHeadline(review) ?? "复盘已生成", strong: true), open: { act(.review(review)) }) }
                        ?? CareerThumb(id: "reviews", name: "复盘", meta: "没有", preview: .empty(icon: "sparkle", text: "这条投递没有复盘", actions: [])),
                    ended.kind == .accepted
                        ? info("start", "入职", [("日期", dotDate(application.text("offer_start_on"))), ("地点", application.text("offer_base_location"))])
                        : info("last", "最后一站", [("站", station.short), ("时间", date(lastSession, "start_at").map(dayLabel))]),
                    info("materials", "资料", [("资料", "\(materialsCount) 份"), ("投递简历", application.text("resume_title_snapshot"))], open: .allMaterials),
                ],
                actions: actions)
        }

        if station.kind == .apply && deck.pending {
            let created = CareerApplication.date(application.text("created_at")) ?? station.start
            return Content(
                title: station.title, status: "待投递", statusTone: "gray",
                hero: Hero(day: created, title: "选一份简历投递", sub: ["\(md(created)) 从岗位看板导入", waited(CareerDeckFormat.dayCount(created, now))].compactMap { $0 }.joined(separator: " · "),
                           note: "投递后记下时间和渠道，之后每一站都接在后面。", tone: "gray"),
                shelfTitle: "投递前",
                shelf: [resumeThumb(pending: true), jobThumb(), info("source", "岗位来源", [("来源", source), ("导入", "\(md(created)) \(clock(created))")])],
                actions: [Action(label: "编辑岗位", run: .editJob), Action(label: "记录投递", kind: .primary, disabled: busy, run: .recordApplied)])
        }
        if station.kind == .apply {
            return Content(
                title: station.title, status: "已投递",
                hero: Hero(day: station.start, title: source.map { "通过\($0)投递" } ?? "已投递", sub: "\(dayLabel(station.start)) \(clock(station.start)) 投递", note: "之后的每一站都接在后面。"),
                shelfTitle: "投递信息",
                shelf: [resumeThumb(), info("channel", "投递渠道", [("渠道", source), ("时间", "\(md(station.start)) \(clock(station.start))")], open: .editDelivery),
                        info("notes", "备注", [("备注", application.text("notes"))], open: .editDelivery)],
                actions: [Action(label: "编辑", run: .editDelivery)])
        }
        if station.kind == .screening && !viewing {
            let applied = CareerApplication.date(application.text("applied_at")) ?? station.start
            return Content(
                title: station.title, status: "等结果",
                hero: Hero(day: applied, title: "等待简历筛选", sub: ["\(dayLabel(applied)) 投递", waited(CareerDeckFormat.dayCount(station.start, now))].compactMap { $0 }.joined(separator: " · "),
                           note: "收到笔试、面试邀请或拒信时，在这里推进。"),
                shelfTitle: "投递信息",
                shelf: [resumeThumb(), jobThumb(),
                        info("channel", "投递渠道", [("渠道", source), ("时间", CareerApplication.date(application.text("applied_at")).map { "\(md($0)) \(clock($0))" })], open: .editDelivery)],
                actions: [Action(label: "补充投递信息", run: .editDelivery), Action(label: "推进到下一步", kind: .primary, disabled: busy, run: .advance)])
        }
        if station.kind == .oc {
            let at = CareerApplication.date(application.text("oc_communicated_at")) ?? station.start
            let salary = application.text("oc_salary_text").nonEmptyValue
            return Content(
                title: station.title, status: station.current ? "等正式 Offer" : "已转正式",
                hero: Hero(day: at, title: salary ?? "口头意向", sub: "\(dayLabel(at)) 沟通 · 以正式 Offer 为准", note: salary != nil ? "口头沟通的薪资" : "已收到口头意向，等待正式 Offer"),
                shelfTitle: "OC 信息",
                shelf: [info("start", "入职时间", [("入职", application.text("oc_start_text"))]), info("contact", "沟通人", [("沟通人", application.text("oc_contact"))]), info("note", "备注", [("备注", application.text("oc_note"))])],
                actions: station.current && !viewing ? [Action(label: "推进到下一步", run: .advance), Action(label: "记录 Offer", kind: .primary, disabled: busy, run: .recordOffer)] : [])
        }
        if station.kind == .offer {
            let received = application.text("offer_status") != "none"
            let due = CareerFormat.offerDate(application.text("offer_reply_due_on"))
            let salary = money(application.display("offer_salary"))
            let months = application.text("offer_benefits_description").range(of: #"(\d{2})\s*薪"#, options: .regularExpression)
                .flatMap { Int(application.text("offer_benefits_description")[$0].prefix(2)) }
            let receivedOn = CareerFormat.offerDate(application.text("offer_received_on")) ?? station.start
            let daysLeft = due.map { CareerFormat.days(from: now, to: $0) }
            let period = application.text("offer_salary_period")
            let yearly = salary != nil && period != "year" && months != nil ? Double(application.display("offer_salary")).map { "年包约 \((($0 * Double(months!)) / 1000).rounded() / 10) 万" } : nil
            let materials = application["offer_materials"]?.items ?? []
            return Content(
                title: station.title, status: received ? "待决定" : "信息待补充",
                hero: Hero(day: due ?? receivedOn, title: salary.map { $0 + (months.map { " × \($0)" } ?? "") } ?? "正式 Offer",
                           sub: due.map { ["\(dayLabel($0)) 答复截止", (daysLeft ?? -1) >= 0 ? "还剩 \(daysLeft!) 天" : "已过截止"].joined(separator: " · ") }
                               ?? ["\(dayLabel(receivedOn)) 收到", received ? "还没填答复截止" : "等你补充 Offer 信息"].joined(separator: " · "),
                           note: [period == "year" ? "年薪" : period == "month" ? "月薪" : nil, yearly, application.text("offer_probation").nonEmptyValue.map { "试用期 \($0)" }].compactMap { $0 }.joined(separator: " · ").nonEmptyValue ?? "薪资可以在编辑 Offer 里补上"),
                shelfTitle: "Offer",
                shelf: [
                    info("start", "入职", [("日期", dotDate(application.text("offer_start_on"))), ("地点", application.text("offer_base_location"))], open: .editOffer),
                    materials.isEmpty
                        ? CareerThumb(id: "offer-files", name: "Offer 材料", meta: "还没有", preview: .empty(icon: "square.and.arrow.up", text: "Offer 邮件、合同都可以放这里", actions: [("上传", { act(.uploadOffer) })]))
                        : CareerThumb(id: "offer-files", name: "Offer 材料", meta: "\(materials.count) 份", preview: .files(materials.prefix(2).map { $0.text("file_name") }, more: 0), open: { act(.editOffer) }),
                    info("benefits", "福利", [("福利", application.text("offer_benefits_description"))], open: .editOffer),
                ],
                actions: [Action(label: "编辑 Offer", run: .editOffer)] + (received ? [Action(label: "处理 Offer", kind: .primary, disabled: busy, run: .handleOffer)] : []))
        }
        if station.current && !viewing && deck.stageState == "awaiting_schedule" && session == nil {
            let since = written || previous == nil || previous?.kind == .apply || previous?.kind == .screening ? nil : "\(previous!.short)已通过"
            let earlier = written ? [] : fromPrevious()
            return Content(
                title: station.title, status: "待安排",
                hero: Hero(day: station.start, title: written ? "还没有定时间" : "还没有约时间", sub: ["\(relativeDay(station.start)) \(clock(station.start)) 收到通知", since].compactMap { $0 }.joined(separator: " · "),
                           note: written ? "填上截止时间或作答窗口，会出现在面试日程。" : "约好后填上时间和方式，会同步到面试日程。"),
                shelfTitle: written ? "笔试前准备" : earlier.isEmpty ? "面试前准备" : "之前留下的",
                shelf: written ? [jobThumb(), resumeThumb()] : earlier + (earlier.count < 2 ? [jobThumb()] : []) + [resumeThumb()],
                actions: [Action(label: "推进到下一步", run: .advance), Action(label: "安排时间", kind: .primary, disabled: busy, run: .schedule)])
        }
        if let session, session.text("status") == "scheduled", !viewing, let end = date(session, "end_at"), end > now {
            let start = date(session, "start_at") ?? station.start
            let open = session.text("schedule_kind") == "open_window"
            let planStart = date(session, "answer_plan_start_at"), planEnd = date(session, "answer_plan_end_at")
            let left = open ? CareerDeckFormat.remaining(end, now: now, prefix: "还剩") : CareerDeckFormat.remaining(start, now: now)
            let title = open ? "\(relativeDay(end)) \(endClock(end)) 前完成" : "\(relativeDay(start)) \(clock(start)) – \(clock(end))"
            let sub: [String?] = open
                ? [relativeDay(end) == dayLabel(end) ? nil : "\(dayLabel(end)) 截止",
                   planStart != nil && planEnd != nil ? "计划 \(md(planStart)) \(clock(planStart!)) – \(clock(planEnd!))" : "\(md(start)) 起开放，窗口内任选时间完成", left ?? "作答中"]
                : [relativeDay(start) == dayLabel(start) ? nil : dayLabel(start), "\(minutes(session)) 分钟 · \(CareerDeckCopy.mode(session))", left ?? "进行中"]
            let weak = written || previous == nil ? nil : weakThumb(previous!)
            return Content(
                title: station.title, status: "已安排",
                hero: Hero(day: open ? end : start, title: title, sub: sub.compactMap { $0 }.joined(separator: " · "),
                           place: (session.text("mode") == "onsite" && !session.text("location").isEmpty) || !session.text("meeting_url").isEmpty ? session : nil),
                shelfTitle: written ? "笔试前准备" : "面试前准备",
                shelf: [prepThumb(session), weak ?? jobThumb(), filesThumb(session)],
                actions: [Action(label: "修改时间", run: .reschedule), Action(label: written ? "做完了，记录结果" : "面完了，记录结果", kind: .primary, disabled: busy, run: .advance)])
        }
        if let session {
            let start = date(session, "start_at") ?? station.start, end = date(session, "end_at") ?? start
            let open = session.text("schedule_kind") == "open_window"
            let current = station.current && !viewing
            let planStart = date(session, "answer_plan_start_at"), planEnd = date(session, "answer_plan_end_at")
            let when = open
                ? planStart != nil && planEnd != nil ? "\(md(planStart)) \(clock(planStart!)) – \(clock(planEnd!))" : "\(md(start)) – \(md(end)) 作答窗口"
                : "\(md(start)) \(clock(start)) – \(clock(end))"
            let how = open ? nil : CareerDeckCopy.mode(session)
            var status: String, tone: String? = nil, hero: Hero
            if current {
                let finished = open && planEnd != nil && planEnd! < end ? planEnd! : end
                let days = CareerDeckFormat.dayCount(finished, now)
                // 场次仍是 scheduled 但已过结束时间：按时间自动视为已面完 / 已做完
                let auto = application.text("stage_state") == "scheduled"
                status = days > 0 ? "等结果" : written ? "已做完" : "已面完"
                hero = Hero(day: open && planStart != nil ? planStart! : start,
                            title: days > 0 ? (written ? "做完了，等结果" : "面完了，等结果") : written ? "笔试结果出来了吗？" : "结果出来了吗？",
                            sub: [when, how, waited(days)].compactMap { $0 }.joined(separator: " · "),
                            note: days > 0 ? nil : auto ? (written ? "作答时间已过，自动标为已做完。趁记得把题目记下来。" : "面试时间已过，自动标为已面完。趁记得把问题记下来。") : "过了就添加下一阶段，没过也在这里标记。")
            } else {
                let resultDays = station.end.map { CareerDeckFormat.dayCount(end, $0) }
                let failed = station.result == "rejected"
                status = failed ? "没通过" : "已通过"; tone = failed ? "red" : nil
                hero = Hero(day: open && planStart != nil ? planStart! : start, title: failed ? "\(station.short)没通过" : "\(station.short)已通过",
                            sub: [when, how, resultDays != nil && !failed ? "\(resultDays!) 天后出结果" : nil].compactMap { $0 }.joined(separator: " · "), tone: tone)
            }
            let shelf: [CareerThumb]
            if written {
                let used = open ? (planStart != nil && planEnd != nil ? max(1, Int((planEnd!.timeIntervalSince(planStart!) / 60).rounded())) : nil) : minutes(session)
                shelf = [writtenThumb(session), CareerDeck.hasReview(session) ? reviewThumb(session) : info("used", "用时", [("用时", used.map { "\($0) 分钟" }), ("时间", when)]), filesThumb(session)]
            } else {
                shelf = [recordThumb(session), reviewThumb(session), filesThumb(session)]
            }
            let reviewed = CareerDeck.hasReview(session)
            return Content(
                title: station.title, status: status, statusTone: tone, hero: hero,
                shelfTitle: current ? (written ? "笔试题与复盘" : "面试记录与复盘") : "这一站留下的", shelf: shelf,
                actions: current ? reject + [Action(label: "添加下一阶段", kind: .primary, disabled: busy, run: .advance)]
                    : [Action(label: "修改面试信息", run: .reschedule),
                       Action(label: reviewed ? "查看复盘" : written ? "查看笔试题" : "查看面试记录", kind: .primary, run: reviewed ? .review(session) : .materials(session.text("id")))])
        }
        if station.current && !viewing {
            let earlier = fromPrevious()
            return Content(
                title: station.title, status: "等结果",
                hero: Hero(day: station.start, title: "等\(station.short)的结果", sub: ["\(dayLabel(station.start)) 进入这一站", waited(CareerDeckFormat.dayCount(station.start, now))].compactMap { $0 }.joined(separator: " · "),
                           note: "这一站没有记下时间。收到通知后，在这里推进到下一步。"),
                shelfTitle: "之前留下的", shelf: earlier + (earlier.count < 2 ? [jobThumb()] : []) + [resumeThumb()],
                actions: reject + [Action(label: "推进到下一步", kind: .primary, disabled: busy, run: .advance)])
        }
        let failed = station.result == "rejected"
        return Content(
            title: station.title, status: failed ? "没通过" : "已通过", statusTone: failed ? "red" : nil,
            hero: Hero(day: station.start, title: failed ? "\(station.short)没通过" : "\(station.short)已通过",
                       sub: station.end.map { "\(dayLabel(station.start)) 进入 · \(CareerDeckFormat.dayCount(station.start, $0)) 天后进入下一站" } ?? dayLabel(station.start),
                       note: "这一站没有记下时间。", tone: failed ? "red" : nil),
            shelfTitle: "这一站",
            shelf: [info("entered", "进入这一站", [("日期", "\(md(station.start)) \(clock(station.start))")]),
                    info("left", "进入下一站", [("日期", station.end.map { "\(md($0)) \(clock($0))" })]),
                    info("days", "用时", [("用时", station.end.map { "\(CareerDeckFormat.dayCount(station.start, $0)) 天" })])],
            actions: [])
    }
}
