import DrawOfferCore
import SwiftUI

/// 12 · 安排时间与修改时间（Figma 07 页 84:523，12.01–12.03；Web `progress/ScheduleDialogs.tsx`）：
/// 和推进弹窗同一套骨架——面包屑「投递 › 安排时间」、衬线标题、备注、一排固定宽度的属性胶囊，
/// 时间在胶囊下方的浮层里按日历填（12.04 统一日期时间选择器）。时间和别的安排重叠时提示，可以改时间或「仍然保存」。
/// 接口：安排用 `interview-sessions` + `answer-plan`；修改用 `reschedule` 与 `PUT interview-sessions/{id}`。
struct CareerScheduleSheet: View {
    enum Target {
        /// 当前阶段还没有排期：安排时间（12.01 / 12.02）。
        case arrange(JSONValue)
        /// 已经排了期：修改时间（12.03）。
        case edit(JSONValue)
    }

    let target: Target
    /// 修改时间时用来写面包屑的投递；没有时读场次里的公司与岗位。
    var application: JSONValue? = nil
    let api: any APIClient
    let close: () -> Void
    /// 保存完成；带一句提示时由调用方显示（部分步骤失败）。
    let saved: (String?) -> Void

    private static let writtenTypes: Set<String> = ["assessment", "written_test", "ai_interview"]
    private static let modes: [(String, String)] = [("video", "视频"), ("onsite", "现场"), ("phone", "电话"), ("other", "其他")]

    @State private var prepared = false
    @State private var windowed = false
    @State private var openAt: Date?
    @State private var deadline: Date?
    @State private var planAt: Date?
    @State private var planMinutes = "60"
    @State private var startAt: Date?
    @State private var endAt: Date?
    @State private var minutes = "60"
    @State private var mode = "video"
    @State private var link = ""
    @State private var interviewer = ""
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    @State private var conflict = false
    @State private var requestID = UUID().uuidString.lowercased()

    // MARK: 派生

    private var arranging: JSONValue? { if case .arrange(let app) = target { return app }; return nil }
    private var session: JSONValue? { if case .edit(let value) = target { return value }; return nil }
    private var app: JSONValue { arranging ?? application ?? .null }
    private var stageType: String {
        if let session { return session.text("stage_type") == "other" ? "written_test" : session.text("stage_type") }
        return app["current_stage"]?.text("stage_type").nonEmptyValue ?? app.text("current_stage_type")
    }
    private var written: Bool { session.map { $0.text("stage_type") == "other" } ?? Self.writtenTypes.contains(stageType) }
    private var label: String {
        if let session { return session.text("stage_label").trimmingCharacters(in: .whitespaces).nonEmptyValue ?? (written ? "笔试" : "面试") }
        return app["current_stage"]?.text("stage_label").nonEmptyValue ?? app.text("current_stage_label").nonEmptyValue ?? (written ? "笔试" : "面试")
    }
    private var kindLabel: String { stageType == "assessment" ? "测评" : stageType == "ai_interview" ? "AI 面试" : "笔试" }
    /// 编辑时已归档或已取消的场次只改说明，不动时间。
    private var readOnlySchedule: Bool { session.map { $0.text("status") == "cancelled" || !$0.text("archived_at").isEmpty || !app.text("archived_at").isEmpty } ?? false }
    private var correctingHistory: Bool { !readOnlySchedule && session?.text("status") == "completed" }
    private var sessionWindow: Bool { session?.text("schedule_kind") == "open_window" }
    /// 安排时：笔试类默认截止前完成；AI 面试后端只允许按时参加。
    private var isWindow: Bool { session != nil ? sessionWindow : written && windowed }
    private var usesLocation: Bool { written && arranging != nil ? false : mode == "onsite" || mode == "other" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            crumbs.padding(.horizontal, 25).padding(.top, 19)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(V3.serif(24)).foregroundStyle(V3.txt).frame(height: 34)
                // macOS 26 上字段带 foregroundStyle 时 prompt 颜色会被盖掉：占位字自己叠
                TextField("", text: $note, axis: .vertical)
                    .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1...4).accessibilityLabel("备注")
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty { Text(notePlaceholder).font(V3.sans(14)).foregroundStyle(V3.fnt).allowsHitTesting(false) }
                    }
                    .onChange(of: note) { _, _ in touched() }
                if conflict {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(V3.orange).frame(width: 5, height: 5).padding(.top, 7)
                        Text("这个时间和其他安排重叠。可以改时间，或仍然保存。").font(V3.sans(12.5)).foregroundStyle(V3.sub)
                    }.padding(.top, 4).accessibilityElement(children: .combine)
                }
            }.padding(.horizontal, 25).padding(.top, 23)
            props.padding(.horizontal, 25).padding(.top, 20)
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.horizontal, 25).padding(.top, 12) }
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 20)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在保存…" : conflict ? "仍然保存" : submitLabel) { Task { await save() } }
                    .buttonStyle(V3ButtonStyle(kind: .dark)).disabled(busy || (session != nil && !changed))
            }.padding(.horizontal, 25).padding(.vertical, 15)
        }
        .frame(width: 640, alignment: .leading)
        // 12.01–12.03 属性格按稿定宽（212 / 88 / 130）；推进弹窗那边按内容撑开
        .environment(\.careerPropFixedWidth, true)
        .interactiveDismissDisabled(busy)
        .onAppear(perform: prepare)
    }

    private var title: String {
        if session == nil { return "安排\(label)时间" }
        if readOnlySchedule { return "编辑\(label)信息" }
        return correctingHistory ? "修改\(label)信息" : "修改\(label)时间"
    }
    private var notePlaceholder: String {
        if session == nil { return written ? "添加准备提醒，比如复习两道算法题…" : "添加准备提醒，比如整理两个项目案例…" }
        return readOnlySchedule ? "记录面试官、问到的重点或后续跟进事项" : "添加备注，比如需要准备的材料或注意事项…"
    }
    private var submitLabel: String { session == nil ? "保存安排" : readOnlySchedule ? "保存" : "保存修改" }

    // MARK: 面包屑

    private var crumbs: some View {
        let company = app.text("company_name_snapshot").nonEmptyValue ?? session?.text("company_name") ?? ""
        let job = [company, app.text("job_title_snapshot").nonEmptyValue ?? session?.text("job_title") ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let state = session == nil ? "待安排" : readOnlySchedule ? "已结束" : correctingHistory ? "已完成" : "已安排"
        let step = session == nil ? "安排时间" : readOnlySchedule || correctingHistory ? "编辑信息" : "修改时间"
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(String(company.prefix(1)).nonEmptyValue ?? "企").font(V3.sans(9, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(V3.txt, in: RoundedRectangle(cornerRadius: 4))
                Text(job.nonEmptyValue ?? label).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(1).truncationMode(.tail)
                Text("\(label) · \(state)").font(V3.sans(11, weight: .medium)).foregroundStyle(V3.fnt).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: 320, alignment: .leading)
            .background(V3.field, in: RoundedRectangle(cornerRadius: 6)).help(job)
            Text("›").font(V3.sans(13)).foregroundStyle(V3.fnt2)
            HStack(spacing: 5) {
                Image(systemName: step == "编辑信息" ? "pencil" : "calendar").font(.system(size: 11))
                Text(step).font(V3.sans(12.5, weight: .medium))
            }.foregroundStyle(V3.blue).padding(.horizontal, 8).frame(height: 28).background(V3.blueSoft, in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
    }

    // MARK: 属性胶囊

    @ViewBuilder private var props: some View {
        HStack(spacing: 8) {
            if !readOnlySchedule {
                CareerAdvanceProp(icon: "calendar", width: isWindow ? 248 : 212, value: timeValue, placeholder: isWindow ? "选择日期" : "选择时间",
                                  aside: isWindow ? CareerAdvanceSheet.left(isWindow && session != nil ? endAt : deadline) : (minutesText(minutes), false)) {
                    timePop
                }
            }
            if session == nil && isWindow {
                CareerAdvanceProp(icon: "clock", width: 156, value: planAt.map { CareerAdvanceFormat.dateText($0, time: true) + " · " + minutesText(planMinutes) }, placeholder: "作答计划") {
                    CareerTimePop(slots: [CareerTimeSlot(key: "plan", label: "开始", value: binding($planAt), clearable: true)],
                                  duration: ("用时", binding($planMinutes)), hint: "只是给自己排的时间，不改官方截止")
                }
            }
            if !readOnlySchedule && !(session == nil && written) {
                Menu {
                    ForEach(modeOptions, id: \.0) { item in Button(item.1 + (mode == item.0 ? " ✓" : "")) { mode = item.0; touched() } }
                } label: {
                    CareerAdvancePropLabel(icon: mode == "phone" ? "phone" : usesLocation ? "mappin" : "video",
                                           text: Self.modes.first { $0.0 == mode }?.1 ?? "视频", empty: false, width: 88, chevron: true)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("方式")
            }
            if !readOnlySchedule || !usesLocation {
                CareerAdvanceTextProp(icon: usesLocation ? "mappin" : "link", label: linkLabel, text: Binding(get: { link }, set: { link = $0; touched() }),
                                      width: session != nil ? (isWindow || readOnlySchedule ? 200 : 160) : written ? 156 : 130,
                                      placeholder: usesLocation ? "例如：北京市海淀区示例大厦" : "粘贴链接", limit: usesLocation ? 500 : 2048)
            }
            if session == nil && !written {
                CareerAdvanceTextProp(icon: "person", label: "面试官", text: $interviewer, width: 130, placeholder: "例如：李老师 · 技术负责人", limit: 100)
            }
        }
    }

    private var modeOptions: [(String, String)] { session?.text("mode") == "other" ? Self.modes : Array(Self.modes.prefix(3)) }
    private var linkLabel: String {
        if session == nil { return written ? "\(kindLabel)链接" : usesLocation ? "面试地点" : "会议链接" }
        let kind = written ? "笔试" : "面试"
        return usesLocation ? "\(kind)地点" : written ? "\(kind)链接" : "会议链接"
    }
    private func minutesText(_ value: String) -> String { "\(value.isEmpty ? "0" : value) 分钟" }

    private var timeValue: String? {
        if session != nil {
            guard let startAt else { return nil }
            if isWindow { return endAt.map { "\(CareerAdvanceFormat.dateText(startAt, time: false)) 至 \(CareerAdvanceFormat.dateText($0, time: false))" } }
            return CareerAdvanceFormat.dateText(startAt, time: true)
        }
        if isWindow { return deadline.map { "\(CareerAdvanceFormat.dateText(openAt ?? Date(), time: false)) 至 \(CareerAdvanceFormat.dateText($0, time: false))" } }
        return startAt.map { CareerAdvanceFormat.dateText($0, time: true) }
    }

    /// 12.01 / 12.02：笔试类在浮层顶部切「按时参加 / 截止前完成」；修改时只能沿用原来的方式。
    @ViewBuilder private var timePop: some View {
        if session != nil {
            if isWindow {
                CareerTimePop(join: .constant(true), joinLocked: true,
                              slots: [CareerTimeSlot(key: "open", label: "开始", value: binding($startAt), placeholder: "今天"),
                                      CareerTimeSlot(key: "deadline", label: "截止", value: binding($endAt), placeholder: "选择日期", clearable: true)])
            } else {
                CareerTimePop(slots: [CareerTimeSlot(key: "start", label: "开始", value: binding($startAt))], duration: ("时长", binding($minutes)))
            }
        } else if written {
            CareerTimePop(join: Binding(get: { windowed }, set: { windowed = $0; touched() }), windowDisabled: stageType == "ai_interview",
                          slots: windowed
                            ? [CareerTimeSlot(key: "open", label: "开始", value: binding($openAt), placeholder: "今天"),
                               CareerTimeSlot(key: "deadline", label: "截止", value: binding($deadline), placeholder: "选择日期", clearable: true)]
                            : [CareerTimeSlot(key: "start", label: "开始", value: binding($startAt))],
                          duration: windowed ? nil : ("时长", binding($minutes)))
        } else {
            CareerTimePop(slots: [CareerTimeSlot(key: "start", label: "开始", value: binding($startAt))], duration: ("时长", binding($minutes)))
        }
    }

    /// 任何改动都清掉错误和冲突提示。
    private func binding<Value>(_ source: Binding<Value>) -> Binding<Value> {
        Binding(get: { source.wrappedValue }, set: { source.wrappedValue = $0; touched() })
    }
    private func touched() { error = nil; conflict = false }

    // MARK: 状态

    private var initialMinutes: Int {
        guard let session, let start = CareerApplication.date(session.text("start_at")), let end = CareerApplication.date(session.text("end_at")) else { return 60 }
        return max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
    }
    private var sessionUsesLocation: Bool { ["onsite", "other"].contains(session?.text("mode") ?? "") }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let session {
            startAt = CareerApplication.date(session.text("start_at"))
            endAt = CareerApplication.date(session.text("end_at"))
            minutes = String(initialMinutes)
            mode = session.text("mode").nonEmptyValue ?? "video"
            link = sessionUsesLocation ? session.text("location") : session.text("meeting_url")
            note = session.text("preparation_note")
        } else {
            windowed = written && stageType != "ai_interview"
        }
    }

    private var duration: Int { Int(minutes) ?? 0 }
    private var roundNo: JSONValue {
        guard let value = app["current_round_no"], value != .null else { return .null }
        return .number(Double(value.integer))
    }
    private var editedEnd: Date? {
        guard let startAt else { return nil }
        return isWindow ? endAt : duration > 0 ? startAt.addingTimeInterval(Double(duration) * 60) : nil
    }
    private var scheduleChanged: Bool {
        guard let session, !readOnlySchedule, let startAt, let end = editedEnd else { return false }
        let start0 = CareerApplication.date(session.text("start_at")), end0 = CareerApplication.date(session.text("end_at"))
        return startAt != start0 || (isWindow ? end != end0 : duration != initialMinutes)
    }
    private var placeValue: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modeChanged: Bool { !readOnlySchedule && mode != (session?.text("mode") ?? mode) }
    private var placeChanged: Bool {
        guard let session else { return false }
        let mode = readOnlySchedule ? session.text("mode") : self.mode
        return ["onsite", "other"].contains(mode)
            ? placeValue != session.text("location") || (!readOnlySchedule && !session.text("meeting_url").isEmpty)
            : placeValue != session.text("meeting_url") || (!readOnlySchedule && !session.text("location").isEmpty)
    }
    private var detailsChanged: Bool { modeChanged || placeChanged }
    private var noteChanged: Bool { note != (session?.text("preparation_note") ?? "") }
    private var changed: Bool { scheduleChanged || detailsChanged || noteChanged }

    // MARK: 保存

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func trimmed(_ text: String) -> JSONValue { text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue.map(JSONValue.string) ?? .null }
    private func isConflict(_ error: Error) -> Bool { if case APIError.server(_, "INTERVIEW_TIME_CONFLICT") = error { return true }; return false }

    private func save() async {
        guard !busy else { return }
        if session != nil { await saveEdit() } else { await saveArrange() }
    }

    private func saveArrange() async {
        let allowConflict = conflict
        if isWindow && deadline == nil { error = "请选择截止时间。"; return }
        if isWindow, let deadline, deadline <= (openAt ?? Date()) { error = "截止时间必须晚于可开始作答时间。"; return }
        if !isWindow && startAt == nil { error = "请选择开始时间。"; return }
        if !isWindow && duration <= 0 { error = "持续时长必须大于 0 分钟。"; return }
        if isWindow, let planAt, let deadline, planAt < (openAt ?? .distantPast) || planAt.addingTimeInterval(Double(Int(planMinutes) ?? 0) * 60) > deadline {
            error = "作答计划必须完整落在官方作答时段内。"; return
        }
        busy = true; error = nil
        defer { busy = false }
        let start = isWindow ? openAt ?? Date() : startAt!
        let end = isWindow ? deadline! : start.addingTimeInterval(Double(duration) * 60)
        let onsite = !written && usesLocation
        var body: [String: JSONValue] = [
            "client_request_id": .string(requestID), "application_stage_id": app["current_stage"]?["id"] ?? .null,
            "stage_type": .string(written ? "other" : stageType == "hr" ? "hr" : "interview"),
            "round_no": written || stageType == "hr" ? .null : roundNo,
            "stage_label": .string(label), "start_at": .string(iso(start)), "end_at": .string(iso(end)),
            "schedule_kind": .string(isWindow ? "open_window" : "fixed_slot"), "timezone": .string(Beijing.identifier),
            "mode": .string(written ? "video" : mode), "meeting_url": onsite ? .null : trimmed(link), "location": onsite ? trimmed(link) : .null,
            "preparation_note": trimmed(note), "allow_conflict": .bool(allowConflict),
        ]
        if !written, let name = interviewer.trimmingCharacters(in: .whitespaces).nonEmptyValue { body["interviewer_name"] = .string(name) }
        let created: JSONValue
        do {
            created = try await api.careerRequest(path: "/api/job-applications/\(app.text("id"))/interview-sessions", method: "POST", query: [:], body: .object(body))
        } catch {
            if isConflict(error) && !allowConflict {
                requestID = UUID().uuidString.lowercased(); conflict = true
            } else {
                if case APIError.server(let status, _) = error, [400, 409, 422].contains(status) { requestID = UUID().uuidString.lowercased() }
                self.error = CareerErrors.message(error)
            }
            return
        }
        if isWindow, let planAt, let session = created["session"] {
            do {
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/answer-plan", method: "PUT", query: [:], body: .object([
                    "answer_plan_start_at": .string(iso(planAt)), "answer_plan_end_at": .string(iso(planAt.addingTimeInterval(Double(Int(planMinutes) ?? 60) * 60))),
                    "base_lock_version": session["lock_version"] ?? .number(1),
                ]))
            } catch { saved("排期已保存，但作答计划保存失败，可在安排详情中重试。"); return }
        }
        saved(nil)
    }

    private func saveEdit() async {
        guard let session, changed else { return }
        let allowConflict = conflict
        let valid = readOnlySchedule || (startAt != nil && editedEnd.map { $0 > startAt! } == true && (isWindow || (duration > 0 && duration <= 525_600)))
        if !valid { error = isWindow ? "截止时间必须晚于开放时间。" : "请选择开始时间和时长。"; return }
        busy = true; error = nil
        defer { busy = false }
        let id = session.text("id")
        let timezone = JSONValue.string(session.text("timezone").nonEmptyValue ?? Beijing.identifier)
        var lock = session["lock_version"] ?? .number(1)
        var rescheduled = false
        do {
            if scheduleChanged && !correctingHistory {
                let result = try await api.careerRequest(path: "/api/interview-sessions/\(id)/reschedule", method: "POST", query: [:], body: .object([
                    "start_at": .string(iso(startAt!)), "end_at": .string(iso(editedEnd!)), "timezone": timezone,
                    "allow_conflict": .bool(allowConflict), "base_lock_version": lock,
                ]))
                lock = result["session"]?["lock_version"] ?? lock
                rescheduled = true
            }
            if detailsChanged || noteChanged || (correctingHistory && scheduleChanged) {
                var body: [String: JSONValue] = ["base_lock_version": lock]
                if correctingHistory && scheduleChanged { body["start_at"] = .string(iso(startAt!)); body["end_at"] = .string(iso(editedEnd!)); body["timezone"] = timezone }
                if !readOnlySchedule { body["mode"] = .string(mode) }
                if detailsChanged {
                    if readOnlySchedule { body["meeting_url"] = placeValue.isEmpty ? .null : .string(placeValue) }
                    else { body["meeting_url"] = usesLocation || placeValue.isEmpty ? .null : .string(placeValue); body["location"] = usesLocation && !placeValue.isEmpty ? .string(placeValue) : .null }
                }
                if noteChanged { body["preparation_note"] = trimmed(note) }
                do {
                    _ = try await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "PUT", query: [:], body: .object(body))
                } catch {
                    if !rescheduled { throw error }
                    saved("已更新\(written ? "笔试" : "面试")时间，但其他信息保存失败，请重新打开后修改。"); return
                }
            }
            saved(nil)
        } catch {
            if isConflict(error) && !allowConflict { conflict = true } else { self.error = CareerErrors.message(error) }
        }
    }
}

// MARK: - 12.04 · 统一日期时间选择器

/// 时间浮层里的一项：按时参加只有「开始」，截止前完成是「开始 / 截止」两天。
struct CareerTimeSlot {
    let key: String
    let label: String
    let value: Binding<Date?>
    var placeholder = "选择日期"
    var clearable = false
}

/// 时间浮层（12.01 / 12.02）：笔试类顶部切「按时参加 / 截止前完成」；中间是日历，下面是开始时间、时长或开始 / 截止两天。
/// 截止前完成按天选：第一次点是开始，第二次点是截止；区间定好后再点，以那一天为新的开始。
struct CareerTimePop: View {
    /// true 表示截止前完成。
    var join: Binding<Bool>? = nil
    /// 修改时间时不能换方式。
    var joinLocked = false
    /// AI 面试只能按时参加。
    var windowDisabled = false
    let slots: [CareerTimeSlot]
    var duration: (String, Binding<String>)? = nil
    var hint: String? = nil
    @State private var month = Date()
    @State private var pickingEnd = false
    @State private var clockValid = true

    private var byDay: Bool { join?.wrappedValue == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let join {
                CareerSegment(options: [(false, "按时参加"), (true, "截止前完成")], selection: join,
                              disabled: joinLocked ? [!join.wrappedValue] : windowDisabled ? [true] : [])
                    .padding(.bottom, 14)
            }
            CareerMiniCalendar(month: $month, selected: byDay ? nil : slots.first?.value.wrappedValue,
                               range: byDay ? range : nil, pick: pick)
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 6).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 10) {
                if !byDay, slots.count == 1, let slot = slots.first, let duration {
                    // 按时参加只有一段时间：开始时刻 – 结束时刻，结束按 15 分钟一档换算成时长
                    CareerSpanRow(start: slot.value, minutes: duration.1, clearable: slot.clearable)
                } else {
                ForEach(slots, id: \.key) { slot in row(slot) }
                if let duration {
                    row(duration.0) {
                        HStack(spacing: 4) {
                            TextField("", text: duration.1).textFieldStyle(.plain).font(V3.number(13, weight: .regular)).frame(width: 34)
                                .onChange(of: duration.1.wrappedValue) { _, new in let digits = new.filter(\.isNumber); if digits != new { duration.1.wrappedValue = digits } }
                                .accessibilityLabel(duration.0)
                            Text("分钟").font(V3.sans(13)).foregroundStyle(V3.txt)
                        }.padding(.horizontal, 10).frame(height: 30).background(.white, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
                    }
                }
                }
                if let hint { Text(hint).font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
            }
        }
        .padding(15).frame(width: 280)
        .onAppear { month = (byDay ? slots.last?.value.wrappedValue ?? slots.first?.value.wrappedValue : slots.first?.value.wrappedValue) ?? Date() }
    }

    private var range: (Date, Date?)? {
        guard let first = slots.first?.value.wrappedValue ?? (slots.last?.value.wrappedValue != nil ? Date() : nil) else { return nil }
        return (first, slots.count > 1 ? slots.last?.value.wrappedValue : nil)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(V3.sans(12.5)).foregroundStyle(V3.fnt).frame(width: 26, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func row(_ slot: CareerTimeSlot) -> some View {
        row(slot.label) {
            if byDay {
                Text(slot.value.wrappedValue.map { CareerTimeFormat.day($0) } ?? slot.placeholder)
                    .font(V3.sans(13)).foregroundStyle(slot.value.wrappedValue == nil && slot.placeholder != "今天" ? V3.fnt : V3.txt)
                    .padding(.horizontal, 10).frame(minWidth: 72, alignment: .leading).frame(height: 30)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
            } else {
                CareerClockField(value: slot.value, compact: true, valid: $clockValid)
            }
            if slot.clearable && slot.value.wrappedValue != nil {
                Button { slot.value.wrappedValue = nil } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(V3.fnt).frame(width: 18, height: 18) }
                    .buttonStyle(.plain).accessibilityLabel("清除\(slot.label)")
            }
        }
    }

    private func pick(_ day: Date) {
        let calendar = Beijing.calendar
        if byDay, let start = slots.first, let end = slots.last, slots.count > 1 {
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day) ?? day
            if !pickingEnd || (start.value.wrappedValue != nil && end.value.wrappedValue != nil) {
                // 已经有截止日、还没选过开始时，第一次点直接定截止（开始默认今天）
                if start.value.wrappedValue == nil && end.value.wrappedValue == nil && !pickingEnd && dayStart > calendar.startOfDay(for: Date()) {
                    end.value.wrappedValue = dayEnd; pickingEnd = false; return
                }
                start.value.wrappedValue = dayStart; end.value.wrappedValue = nil; pickingEnd = true; return
            }
            if let begin = start.value.wrappedValue, dayStart < calendar.startOfDay(for: begin) {
                end.value.wrappedValue = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: begin)
                start.value.wrappedValue = dayStart
            } else {
                end.value.wrappedValue = dayEnd
            }
            pickingEnd = false
            return
        }
        guard let slot = slots.first else { return }
        let current = slot.value.wrappedValue
        let hour = current.map { calendar.component(.hour, from: $0) } ?? 10
        let minute = current.map { calendar.component(.minute, from: $0) } ?? 0
        slot.value.wrappedValue = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}

enum CareerTimeFormat {
    /// 「10月15日 周四」。
    static func day(_ date: Date) -> String {
        if Beijing.calendar.isDateInToday(date) { return "今天" }
        let formatter = Beijing.formatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: date)
    }
}

/// 两段切换：选中白底细边，没选的灰字（12.02 顶部「按时参加 / 截止前完成」）。
struct CareerSegment<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var disabled: [Value] = []
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(V3.sans(12.5, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : V3.sub)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? V3.cl : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(disabled.contains(option.0)).opacity(disabled.contains(option.0) ? 0.45 : 1)
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(2).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 月历（12.04）：周一开头；今天蓝圈，选中实心蓝圆；截止前完成时开始到截止整段浅蓝。
struct CareerMiniCalendar: View {
    @Binding var month: Date
    let selected: Date?
    var range: (Date, Date?)? = nil
    let pick: (Date) -> Void
    private static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        let calendar = Beijing.calendar
        let days = Self.grid(month)
        VStack(spacing: 0) {
            HStack {
                Text(CareerMiniCalendar.title(month)).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.sub).accessibilityLabel("上个月")
                Button { shift(1) } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.sub).accessibilityLabel("下个月")
            }.frame(height: 28).padding(.leading, 4)
            HStack(spacing: 0) {
                ForEach(Self.weekdays, id: \.self) { Text($0).font(V3.sans(11.5)).foregroundStyle(V3.fnt).frame(maxWidth: .infinity) }
            }.frame(height: 22).padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                    let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                    let ends = range.map { [$0.0, $0.1].compactMap { $0 }.contains { calendar.isDate($0, inSameDayAs: day) } } ?? false
                    let inside = range.flatMap { item in item.1.map { (item.0, $0) } }.map { calendar.startOfDay(for: day) > calendar.startOfDay(for: $0.0) && calendar.startOfDay(for: day) < calendar.startOfDay(for: $0.1) } ?? false
                    let today = calendar.isDateInToday(day)
                    let past = calendar.startOfDay(for: day) < calendar.startOfDay(for: Date())
                    Button { pick(day); if !inMonth { month = day } } label: {
                        Text("\(calendar.component(.day, from: day))").font(V3.number(12.5, weight: isSelected || ends ? .medium : .regular))
                            .foregroundStyle(isSelected || ends ? .white : !inMonth ? V3.fnt2 : past ? V3.fnt : V3.txt)
                            .frame(width: 36, height: 30)
                            .background { if isSelected || ends { Capsule().fill(V3.blue) } }
                            .overlay { if today && !(isSelected || ends) { Capsule().stroke(V3.blue, lineWidth: 1) } }
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background { if inside { V3.blueSoft.frame(height: 30) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(CareerTimeFormat.day(day)).accessibilityAddTraits(isSelected || ends ? .isSelected : [])
                }
            }
        }
    }

    private func shift(_ value: Int) { month = Beijing.calendar.date(byAdding: .month, value: value, to: month) ?? month }

    static func title(_ date: Date) -> String {
        let parts = Beijing.calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月"
    }

    /// 整周排开：从这个月 1 号所在周的周一，到月底所在周的周日。
    static func grid(_ month: Date) -> [Date] {
        let calendar = Beijing.calendar
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: first) + 5) % 7
        let total = Int(ceil(Double(lead + count) / 7)) * 7
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0 - lead, to: first) }
    }
}

/// 一段时间（13.02）：开始时刻框 – 结束时刻下拉，后面写时长。
struct CareerSpanRow: View {
    let start: Binding<Date?>
    let minutes: Binding<String>
    var clearable = false
    @State private var clockValid = true
    var body: some View {
        HStack(spacing: 6) {
            CareerClockField(value: start, compact: true, valid: $clockValid)
            Text("–").font(V3.sans(13)).foregroundStyle(V3.fnt)
            CareerEndClockMenu(start: start.wrappedValue, minutes: minutes)
            if let value = Int(minutes.wrappedValue), value > 0 {
                Text(CareerTimeSpan.label(value)).font(V3.sans(12.5)).foregroundStyle(V3.fnt).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
            if clearable && start.wrappedValue != nil {
                Button { start.wrappedValue = nil } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(V3.fnt).frame(width: 18, height: 18) }
                    .buttonStyle(.plain).accessibilityLabel("清除开始")
            }
        }
    }
}

/// 结束时刻：从开始往后每 15 分钟一档（共 8 小时），每项写时刻和时长；选了换算回时长。
struct CareerEndClockMenu: View {
    let start: Date?
    @Binding var minutes: String
    var body: some View {
        let current = Int(minutes) ?? 0
        let calendar = Beijing.calendar
        let options = CareerTimeSpan.options(startMinute: start.map { calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0) }, current: current)
        let picked = options.first { $0.minutes == current }
        Menu {
            ForEach(options, id: \.minutes) { option in
                Button { minutes = String(option.minutes) } label: {
                    if option == picked { Label("\(option.clock)  \(option.span)", systemImage: "checkmark") } else { Text("\(option.clock)  \(option.span)") }
                }
            }
        } label: {
            Text(picked?.clock ?? "--:--").font(V3.number(13, weight: .regular)).foregroundStyle(picked == nil ? V3.fnt : V3.txt)
                .frame(width: 71, height: 29)
                .background(.white, in: RoundedRectangle(cornerRadius: 5.5))
                .overlay(RoundedRectangle(cornerRadius: 5.5).stroke(V3.cl))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("结束时刻")
    }
}

/// 时间框（12.04）：直接键入「时 : 分」，Tab 换位；点开在框上方展开小时、分钟两列，点数字立即更新。
/// 格式或数值不对时红框并提示，`valid` 交给外面禁用确认。
struct CareerClockField: View {
    @Binding var value: Date?
    var compact = false
    @Binding var valid: Bool
    @State private var hour = ""
    @State private var minute = ""
    @State private var listOpen = false
    @FocusState private var focus: Part?
    private enum Part { case hour, minute }

    private var parsed: (Int, Int)? {
        guard let h = Int(hour), let m = Int(minute), (0...23).contains(h), (0...59).contains(m), hour.count <= 2, minute.count <= 2 else { return nil }
        return (h, m)
    }

    var body: some View {
        let invalid = parsed == nil && !(hour.isEmpty && minute.isEmpty)
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: compact ? 1 : 4) {
                part($hour, .hour)
                Text(":").font(V3.number(compact ? 13 : 16, weight: .regular)).foregroundStyle(V3.fnt)
                part($minute, .minute)
            }
            .padding(.horizontal, compact ? 8 : 14).frame(width: compact ? 71 : 147, height: compact ? 29 : 39)
            .background(.white, in: RoundedRectangle(cornerRadius: compact ? 5.5 : 7.5))
            .overlay(RoundedRectangle(cornerRadius: compact ? 5.5 : 7.5).stroke(invalid ? V3.red : focus != nil || listOpen ? V3.blue : V3.cl, lineWidth: invalid || focus != nil ? 1.2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { listOpen.toggle(); if focus == nil { focus = .hour } }
            .overlay(alignment: .bottomLeading) { if listOpen { lists.offset(y: -(compact ? 34 : 44)).zIndex(10) } }
            .zIndex(listOpen ? 10 : 0)
            if invalid { Text("请输入有效时间，例如 09:30").font(V3.sans(11.5)).foregroundStyle(V3.red) }
        }
        .onAppear(perform: sync)
        .onChange(of: value) { _, _ in if focus == nil { sync() } }
        .onChange(of: focus) { _, new in if new != nil { listOpen = true } }
        .onChange(of: hour) { _, _ in commit() }
        .onChange(of: minute) { _, _ in commit() }
    }

    private func part(_ text: Binding<String>, _ which: Part) -> some View {
        TextField("--", text: text).textFieldStyle(.plain).multilineTextAlignment(.center)
            .font(V3.number(compact ? 13 : 18, weight: compact ? .regular : .medium)).foregroundStyle(focus == which ? V3.blue : V3.txt)
            .frame(width: compact ? 20 : 30).focused($focus, equals: which)
            .onChange(of: text.wrappedValue) { _, new in
                let digits = String(new.filter(\.isNumber).prefix(2))
                if digits != new { text.wrappedValue = digits }
                if which == .hour && digits.count == 2 { focus = .minute }
            }
            .onSubmit { listOpen = false; focus = nil }
            .accessibilityLabel(which == .hour ? "小时" : "分钟")
    }

    /// 小时 00–23、分钟 00–59 两列，独立滚动。
    private var lists: some View {
        HStack(alignment: .top, spacing: 6) {
            column("小时", 0..<24, selected: Int(hour)) { hour = String(format: "%02d", $0) }
            column("分钟", 0..<60, selected: Int(minute)) { minute = String(format: "%02d", $0); listOpen = false }
        }
        .padding(8).frame(width: 148, height: 176)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .fixedSize()
    }

    private func column(_ title: String, _ values: Range<Int>, selected: Int?, pick: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 4) {
            Text(title).font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height: 16)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(values), id: \.self) { item in
                            Button { pick(item) } label: {
                                Text(String(format: "%02d", item)).font(V3.number(13, weight: .regular))
                                    .foregroundStyle(item == selected ? V3.blue : V3.txt)
                                    .frame(maxWidth: .infinity).frame(height: 28)
                                    .background(item == selected ? V3.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(item)
                        }
                    }
                }.onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
        }.frame(maxWidth: .infinity)
    }

    private func sync() {
        guard let value else { hour = ""; minute = ""; return }
        let calendar = Beijing.calendar
        hour = String(format: "%02d", calendar.component(.hour, from: value))
        minute = String(format: "%02d", calendar.component(.minute, from: value))
    }

    private func commit() {
        let ok = parsed != nil || (hour.isEmpty && minute.isEmpty)
        if valid != ok { valid = ok }
        guard let time = parsed else { return }
        let (h, m) = time
        let base = value ?? Date()
        let next = Beijing.calendar.date(bySettingHour: h, minute: m, second: 0, of: base)
        if next != value { value = next }
    }
}
