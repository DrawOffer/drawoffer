import DrawOfferCore
import SwiftUI

/// 11 · 推进流程（Figma 07 页 84:343，Linear 骨架 + 07 风格；Web `progress/AdvanceDialog.tsx`）：
/// 顶部面包屑「流程 › 这次的进展」，进展按进度预选、点开可换（11.02）；下面是这一站的衬线标题、备注和一排固定宽度的
/// 属性胶囊：必填的带默认值，选填的是虚线「+」，点开在下方浮层里填（11.03）；底部一个主按钮跟着进展变。
/// 接口沿用 `stages`、`interview-sessions`、`answer-plan`、`offer`、`terminate`，失败重试复用同一请求号。
struct CareerAdvanceSheet: View {
    enum Kind: String, CaseIterable { case written, interview, oc, offer, rejected, withdraw }

    private let seed: JSONValue
    let api: any APIClient
    let initialKind: Kind?
    /// 看板拖到测评 / 笔试列时预选的类型。
    let initialWrittenType: String
    /// 看板拖到某一轮面试列时预填的面试名称。
    let initialInterviewLabel: String
    /// 从面试日程新建：面包屑第一段在这些岗位里选（只出现笔试 / 测评与面试两种进展）。
    let applicationOptions: [JSONValue]?
    /// 面试日程里选中的时间段，带入时间胶囊。
    let initialStart: Date?
    let initialEnd: Date?
    let close: () -> Void
    let completed: (String?) -> Void

    init(application: JSONValue, api: any APIClient, initialKind: Kind? = nil, initialWrittenType: String = "written_test", initialInterviewLabel: String = "",
         applicationOptions: [JSONValue]? = nil, initialStart: Date? = nil, initialEnd: Date? = nil,
         close: @escaping () -> Void, completed: @escaping (String?) -> Void) {
        seed = application; self.api = api; self.initialKind = initialKind; self.initialWrittenType = initialWrittenType
        self.initialInterviewLabel = initialInterviewLabel; self.applicationOptions = applicationOptions
        self.initialStart = initialStart; self.initialEnd = initialEnd; self.close = close; self.completed = completed
    }

    @State private var pickedID: String?
    private var fromSchedule: Bool { applicationOptions != nil }
    private var application: JSONValue { applicationOptions?.first { $0.text("id") == pickedID } ?? seed }

    private static let choices: [Kind: (icon: String, title: String)] = [
        .written: ("pencil", "收到笔试 / 测评通知"), .interview: ("person", "收到面试通知"), .oc: ("phone", "拿到 OC"),
        .offer: ("envelope", "收到正式 Offer"), .rejected: ("xmark", "没通过"), .withdraw: ("flag", "我不继续了"),
    ]
    private static let writtenLabels: [(String, String)] = [("written_test", "笔试"), ("assessment", "测评"), ("ai_interview", "AI 面试")]
    private static let rounds = ["一面", "二面", "三面"]

    @State private var kind: Kind = .interview
    @State private var busy = false
    @State private var error: String?
    @State private var ids = (stage: UUID().uuidString.lowercased(), session: UUID().uuidString.lowercased(), terminate: UUID().uuidString.lowercased())
    @State private var savedStage: JSONValue?
    @State private var savedNotes: JSONValue?
    @State private var prepared = false

    // 笔试 / 测评
    @State private var writtenType = "written_test"
    @State private var windowed = true
    @State private var openAt: Date?
    @State private var deadline: Date?
    @State private var planAt: Date?
    @State private var planMinutes = "60"
    // 面试
    @State private var interviewType = "interview"
    @State private var round = "1"
    @State private var customName = ""
    @State private var mode = "video"
    @State private var interviewer = ""
    // 面试与笔试共用
    @State private var startAt: Date?
    @State private var minutes = "60"
    @State private var undecided = false
    @State private var link = ""
    @State private var prepNote = ""
    // OC
    @State private var ocAt: Date?
    @State private var ocSalary = ""
    @State private var ocStart = ""
    @State private var ocContact = ""
    // Offer
    @State private var receivedOn: Date? = Date()
    @State private var replyDue: Date?
    @State private var salary = ""
    @State private var salaryPeriod = "month"
    @State private var startOn: Date?
    @State private var location = ""
    @State private var probation = ""
    @State private var benefits = ""
    // 没通过 / 我不继续了
    @State private var noticeOn: Date?
    @State private var note = ""

    private var currentStageType: String { application["current_stage"]?.text("stage_type").nonEmptyValue ?? application.text("current_stage_type") }
    private var currentLabel: String { application["current_stage"]?.text("stage_label").nonEmptyValue ?? application.text("current_stage_label") }
    private var taken: [(round: Int?, label: String)] { Self.taken(application) }
    private var nextRound: Int { Self.nextRound(application) }
    private static func taken(_ application: JSONValue) -> [(round: Int?, label: String)] {
        var seen = Set<String>()
        return ((application["stages"]?.items ?? []) + [application["current_stage"] ?? .null]).compactMap { stage in
            guard stage.text("stage_type") == "interview", seen.insert(stage.text("id")).inserted else { return nil }
            return (stage["interview_round_no"]?.numberValue.map { Int($0) }, stage.text("stage_label").trimmingCharacters(in: .whitespaces).lowercased())
        }
    }
    private static func nextRound(_ application: JSONValue) -> Int {
        let type = application["current_stage"]?.text("stage_type").nonEmptyValue ?? application.text("current_stage_type")
        return max(0, taken(application).compactMap(\.round).max() ?? 0, type == "interview" ? application["current_round_no"]?.integer ?? 0 : 0) + 1
    }
    private var nextKinds: [Kind] { fromSchedule ? [.written, .interview] : currentStageType == "oc" ? [.offer] : [.written, .interview, .oc, .offer] }
    private var endKinds: [Kind] { fromSchedule ? [] : application.text("offer_status") == "none" || application.text("offer_status").isEmpty ? [.rejected, .withdraw] : [.rejected] }
    private var suggested: Kind { currentStageType == "oc" ? .offer : currentStageType == "screening" ? .written : .interview }
    private var roundNo: Int { round == "custom" ? Self.inferRound(customName) ?? nextRound : Int(round) ?? nextRound }
    private var interviewLabel: String {
        interviewType == "hr" ? "HR 面" : round == "custom" ? customName.trimmingCharacters(in: .whitespaces) : Self.rounds[max(0, min(2, (Int(round) ?? 1) - 1))]
    }
    private var nameTaken: Bool {
        kind == .interview && interviewType == "interview" && taken.contains { $0.round == roundNo || $0.label == interviewLabel.lowercased() }
    }
    private var writtenName: String { Self.writtenLabels.first { $0.0 == writtenType }?.1 ?? "笔试" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            crumbs.padding(.horizontal, 25).padding(.top, 19)
            VStack(alignment: .leading, spacing: 6) {
                title
                if let placeholder = notePlaceholder {
                    TextField("", text: kind == .written || kind == .interview ? $prepNote : $note, prompt: Text(placeholder).foregroundStyle(CareerAdvanceStyle.placeholder), axis: .vertical)
                        .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1...4).accessibilityLabel("备注")
                }
                if kind == .oc { info("OC 是口头意向；收到书面 Offer 后，再记录正式 Offer。") }
                if nameTaken { Text("这一轮已经加过了").font(V3.sans(12.5)).foregroundStyle(V3.red) }
            }.padding(.horizontal, 25).padding(.top, 20)
            props.padding(.horizontal, 25).padding(.top, 20)
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.horizontal, 25).padding(.top, 12) }
            // 稿：分隔线 #EEF1F6，上沿离属性 20，按钮上下各 15
            Rectangle().fill(CareerAdvanceStyle.divider).frame(height: 1).padding(.top, 20)
            HStack(spacing: 10) {
                if kind == .written || kind == .interview {
                    Toggle(isOn: $undecided) { Text("时间还没定").font(V3.sans(12.5)).foregroundStyle(V3.sub) }.toggleStyle(.switch).controlSize(.mini)
                } else if let hint {
                    Text(hint).font(V3.sans(12)).foregroundStyle(CareerAdvanceStyle.hint)
                }
                Spacer(minLength: 0)
                Button("取消", action: close).buttonStyle(CareerAdvanceButtonStyle()).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在保存…" : submitLabel) { Task { await save() } }
                    .buttonStyle(CareerAdvanceButtonStyle(kind: kind == .rejected ? .danger : .dark)).disabled(busy || nameTaken)
            }.padding(.horizontal, 25).padding(.vertical, 15)
        }
        .frame(width: 640, alignment: .leading)
        .interactiveDismissDisabled(busy)
        .onAppear(perform: prepare)
    }

    // MARK: 面包屑

    private var crumbs: some View {
        let job = application.text("company_name_snapshot") + " · " + application.text("job_title_snapshot")
        let state = ["awaiting_schedule": "等待安排", "scheduled": "已安排", "awaiting_result": "等待结果", "negotiating": "沟通中"][application.text("stage_state")]
        let tag = [currentLabel.nonEmptyValue, state].compactMap { $0 }.joined(separator: " · ")
        let choice = Self.choices[kind]!
        return HStack(spacing: 8) {
            if let options = applicationOptions {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button { pick(option) } label: {
                            let text = [option.text("company_name_snapshot"), option.text("job_title_snapshot"), option.text("current_stage_label")].filter { !$0.isEmpty }.joined(separator: " · ")
                            if option.text("id") == application.text("id") { Label(text, systemImage: "checkmark") } else { Text(text) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(String(application.text("company_name_snapshot").prefix(1)).nonEmptyValue ?? "企").font(V3.sans(9.5, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(V3.txt, in: RoundedRectangle(cornerRadius: 4))
                        Text(job).font(V3.sans(12.5)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail)
                        if !tag.isEmpty { Text(tag).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1).fixedSize() }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(V3.fnt)
                    }
                    .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: 360, alignment: .leading)
                    .background(CareerAdvanceStyle.crumb, in: RoundedRectangle(cornerRadius: 6)).contentShape(RoundedRectangle(cornerRadius: 6))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(savedStage != nil || busy).accessibilityLabel("选择岗位").help(job)
            } else {
            HStack(spacing: 6) {
                Text(String(application.text("company_name_snapshot").prefix(1)).nonEmptyValue ?? "企").font(V3.sans(9.5, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(V3.txt, in: RoundedRectangle(cornerRadius: 4))
                Text(job).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(1).truncationMode(.tail)
                if !tag.isEmpty { Text(tag).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: 320, alignment: .leading)
            .background(CareerAdvanceStyle.crumb, in: RoundedRectangle(cornerRadius: 6)).help(job)
            }
            Text("›").font(V3.sans(14)).foregroundStyle(CareerAdvanceStyle.placeholder)
            Menu {
                ForEach(nextKinds, id: \.self) { item in
                    Button { choose(item) } label: { Label(Self.choices[item]!.title + (item == suggested ? " · 按进度推荐" : ""), systemImage: kind == item ? "checkmark" : Self.choices[item]!.icon) }
                }
                if !endKinds.isEmpty { Divider() }
                ForEach(endKinds, id: \.self) { item in
                    Button(role: item == .rejected ? .destructive : nil) { choose(item) } label: { Label(Self.choices[item]!.title, systemImage: kind == item ? "checkmark" : Self.choices[item]!.icon) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: choice.icon).font(.system(size: 11))
                    Text(choice.title).font(V3.sans(12.5, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(kind == .rejected ? V3.red : CareerAdvanceStyle.blueText).padding(.horizontal, 10).frame(height: 28)
                .background(kind == .rejected ? V3.redSoft : CareerAdvanceStyle.blueSoft, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("换成别的进展")
            Spacer(minLength: 0)
        }
    }

    // MARK: 标题与属性

    @ViewBuilder private var title: some View {
        switch kind {
        case .written:
            titlePick(writtenName) {
                ForEach(Self.writtenLabels, id: \.0) { item in Button(item.1 + (writtenType == item.0 ? " ✓" : "")) { writtenType = item.0 } }
            }
        case .interview:
            HStack(spacing: 6) {
                if interviewType == "interview" && round == "custom" {
                    TextField("面试名称", text: $customName).textFieldStyle(.plain).font(V3.serif(24)).foregroundStyle(V3.txt).frame(maxWidth: 260).accessibilityLabel("面试名称")
                } else {
                    Text(interviewLabel).font(V3.serif(24)).foregroundStyle(V3.txt)
                }
                Menu {
                    ForEach(Array(Self.rounds.enumerated()), id: \.offset) { index, name in
                        let used = taken.contains { $0.round == index + 1 || $0.label == name }
                        Button(name + (interviewType == "interview" && round == String(index + 1) ? " ✓" : "")) { interviewType = "interview"; round = String(index + 1) }.disabled(used)
                    }
                    Button("HR 面" + (interviewType == "hr" ? " ✓" : "")) { interviewType = "hr" }
                    Button("自定义" + (interviewType == "interview" && round == "custom" ? " ✓" : "")) { interviewType = "interview"; round = "custom" }
                } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(V3.fnt).frame(width: 22, height: 22) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("轮次")
            }.frame(height: 34)
        case .oc: plainTitle("OC")
        case .offer: plainTitle("正式 Offer")
        case .rejected: plainTitle("\(currentLabel)没通过")
        case .withdraw: plainTitle("结束这次求职")
        }
    }

    private func plainTitle(_ text: String) -> some View { Text(text).font(V3.serif(24)).foregroundStyle(V3.txt).frame(height: 34) }

    private func titlePick<Items: View>(_ text: String, @ViewBuilder items: () -> Items) -> some View {
        Menu { items() } label: {
            HStack(spacing: 6) {
                Text(text).font(V3.serif(24)).foregroundStyle(V3.txt)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(V3.fnt)
            }
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().frame(height: 34).accessibilityLabel("类型")
    }

    private func info(_ text: String) -> some View {
        // 稿 11.06：整行浅蓝灰底 #F6F8FC、圆角 8、高 33，文字 12.5
        Text(text).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(2)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
            .background(CareerAdvanceStyle.infoBox, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 4)
    }

    private var notePlaceholder: String? {
        switch kind {
        case .written: return "添加备注，比如笔试范围…"
        case .interview: return "添加备注，比如要准备的内容…"
        case .oc: return "添加备注，比如 HR 说了什么…"
        case .offer: return nil
        case .rejected: return "写点给自己的备注，比如哪里没答好…"
        case .withdraw: return "写点原因，比如已接受其他 Offer…"
        }
    }
    private var hint: String? {
        switch kind {
        case .oc: return "状态变为「OC · 沟通中」"
        case .offer: return "之后在详情页接受或婉拒"
        case .rejected: return "阶段记录、复盘和资料都会保留"
        case .withdraw: return "状态变为「已主动结束」，记录都会保留"
        default: return nil
        }
    }
    private var submitLabel: String {
        switch kind {
        case .written: return "添加" + writtenName
        case .interview: return "添加" + (interviewLabel.nonEmptyValue ?? "面试")
        case .oc: return "记录 OC"
        case .offer: return "记录 Offer"
        case .rejected: return "记为未通过"
        case .withdraw: return "结束这次求职"
        }
    }

    @ViewBuilder private var props: some View {
        switch kind {
        case .written:
            FlowLayout(spacing: 9) {
                CareerAdvanceProp(icon: "calendar", width: 248, value: undecided ? "等待安排" : writtenTimeText, placeholder: windowed ? "选择日期" : "开始时间",
                                  aside: undecided ? nil : windowed ? Self.left(deadline) : (minutes + " 分钟", false), disabled: undecided) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $windowed) { Text("截止前完成").tag(true); Text("准点开始").tag(false) }.pickerStyle(.segmented).labelsHidden()
                        if windowed {
                            CareerAdvanceDateRow(label: "开始", value: $openAt, time: false, placeholder: "今天")
                            CareerAdvanceDateRow(label: "截止", value: $deadline, time: false, placeholder: "选择日期", endOfDay: true)
                        } else {
                            CareerAdvanceDateRow(label: "开始", value: $startAt, time: true)
                            endRow(start: startAt, $minutes)
                        }
                    }
                }
                if windowed {
                    CareerAdvanceProp(icon: "clock", width: 156, value: planAt.map { CareerAdvanceFormat.dateText($0, time: true) + " · \(planMinutes) 分钟" }, placeholder: "作答计划", disabled: undecided) {
                        VStack(alignment: .leading, spacing: 10) {
                            CareerAdvanceDateRow(label: "开始", value: $planAt, time: true, clearable: true)
                            endRow(start: planAt, $planMinutes)
                            Text("只是给自己排的时间，不改官方截止").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                        }
                    }
                }
                CareerAdvanceTextProp(icon: "link", label: "笔试链接", text: $link, width: 156, placeholder: "粘贴链接", limit: 2048)
            }
        case .interview:
            FlowLayout(spacing: 9) {
                CareerAdvanceProp(icon: "calendar", width: 212, value: undecided ? "等待安排" : startAt.map { CareerAdvanceFormat.dateText($0, time: true) }, placeholder: "选择时间",
                                  aside: undecided ? nil : (minutes + " 分钟", false), disabled: undecided) {
                    VStack(alignment: .leading, spacing: 10) {
                        CareerAdvanceDateRow(label: "开始", value: $startAt, time: true)
                        endRow(start: startAt, $minutes)
                    }
                }
                Menu {
                    ForEach([("video", "视频"), ("onsite", "现场"), ("phone", "电话")], id: \.0) { item in Button(item.1 + (mode == item.0 ? " ✓" : "")) { mode = item.0 } }
                } label: {
                    CareerAdvancePropLabel(icon: mode == "phone" ? "phone" : mode == "onsite" ? "mappin" : "video", text: ["video": "视频", "onsite": "现场", "phone": "电话"][mode] ?? "视频", empty: false, width: 88, chevron: true)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("方式")
                CareerAdvanceTextProp(icon: mode == "onsite" ? "mappin" : "link", label: mode == "onsite" ? "面试地点" : "会议链接", text: $link, width: 130,
                                      placeholder: mode == "onsite" ? "例如：北京市海淀区示例大厦" : "粘贴腾讯会议 / 飞书 / Zoom 链接", limit: mode == "onsite" ? 500 : 2048)
                CareerAdvanceTextProp(icon: "person", label: "面试官", text: $interviewer, width: 130, placeholder: "例如：李老师 · 技术负责人", limit: 100)
            }
        case .oc:
            FlowLayout(spacing: 9) {
                CareerAdvanceProp(icon: "calendar", width: 190, value: ocAt.map { CareerAdvanceFormat.dateText($0, time: true) }, placeholder: "沟通时间", lead: "沟通") {
                    CareerAdvanceDateRow(label: "沟通", value: $ocAt, time: true)
                }
                CareerAdvanceTextProp(icon: "doc", label: "口头薪资", text: $ocSalary, width: 130, placeholder: "例如：35K × 16", limit: 100)
                CareerAdvanceTextProp(icon: "person", label: "联系人", text: $ocContact, width: 120, placeholder: nil, limit: 100)
                CareerAdvanceTextProp(icon: "calendar", label: "预计入职", text: $ocStart, width: 120, placeholder: "例如：明年 7 月", limit: 100)
            }
        case .offer:
            FlowLayout(spacing: 9) {
                dateProp("收到", $receivedOn, width: 156)
                CareerAdvanceProp(icon: "calendar", width: 232, value: replyDue.map { CareerAdvanceFormat.dateText($0, time: false) }, placeholder: "答复截止", aside: Self.left(replyDue), lead: "答复截止") {
                    CareerAdvanceDateRow(label: "答复截止", value: $replyDue, time: false, clearable: true)
                }
                CareerAdvanceProp(icon: "doc", width: 164, value: salary.trimmingCharacters(in: .whitespaces).nonEmptyValue.map { "\($0) / " + (salaryPeriod == "year" ? "年" : "月") }, placeholder: "薪资") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("金额").font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(width: 40, alignment: .leading); TextField("36,000", text: $salary).textFieldStyle(.roundedBorder).frame(width: 140) }
                        HStack { Text("周期").font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(width: 40, alignment: .leading); Picker("", selection: $salaryPeriod) { Text("月薪").tag("month"); Text("年薪").tag("year") }.labelsHidden().frame(width: 140) }
                    }
                }
                dateProp("入职", $startOn, width: 156)
                CareerAdvanceTextProp(icon: "mappin", label: "工作地点", text: $location, width: 140, placeholder: "例如：北京", limit: 100)
                CareerAdvanceTextProp(icon: "clock", label: "试用期", text: $probation, width: 120, placeholder: "例如：6 个月", limit: 100)
                CareerAdvanceTextProp(icon: "doc", label: "福利说明", text: $benefits, width: 144, placeholder: "例如：六险一金、餐补", limit: 500)
            }
        case .rejected:
            HStack(spacing: 9) {
                CareerAdvancePropLabel(icon: "person", text: currentLabel, empty: false, width: nil, chevron: true, lead: "哪一步")
                dateProp("收到通知", $noticeOn, width: 200)
            }
        case .withdraw:
            EmptyView()
        }
    }

    private func dateProp(_ label: String, _ value: Binding<Date?>, width: CGFloat) -> some View {
        CareerAdvanceProp(icon: "calendar", width: width, value: value.wrappedValue.map { CareerAdvanceFormat.dateText($0, time: false) }, placeholder: label, lead: label) {
            CareerAdvanceDateRow(label: label, value: value, time: false, clearable: true)
        }
    }

    /// 结束时刻（Web `EndClockInput`）：从开始往后每 15 分钟一档，选了换算回时长。
    private func endRow(start: Date?, _ value: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text("结束").font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(width: 56, alignment: .leading)
            CareerEndClockMenu(start: start, minutes: value)
            if let minutes = Int(value.wrappedValue), minutes > 0 { Text(CareerTimeSpan.label(minutes)).font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
        }
    }

    private var writtenTimeText: String? {
        if windowed { return deadline.map { "\(CareerAdvanceFormat.dateText(openAt ?? Date(), time: false)) 至 \(CareerAdvanceFormat.dateText($0, time: false))" } }
        return startAt.map { CareerAdvanceFormat.dateText($0, time: true) }
    }

    /// 时间胶囊右侧的提示：还剩 N 天 / 今天截止 / 已过截止。
    static func left(_ date: Date?) -> (String, Bool)? {
        guard let date else { return nil }
        let days = CareerFormat.days(from: Date(), to: date)
        if days < 0 || date < Date() { return ("已过截止", true) }
        return (days == 0 ? "今天截止" : "还剩 \(days) 天", false)
    }

    static func inferRound(_ label: String) -> Int? {
        let text = label.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "\\d+(?=\\s*(轮|面))", options: .regularExpression), let value = Int(text[range]), value > 0 { return value }
        let numerals: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let body = text.hasPrefix("第") ? text.dropFirst().trimmingCharacters(in: .whitespaces) : text
        guard let first = body.first, let value = numerals[first], body.dropFirst().first.map({ $0 == "面" || $0 == "轮" }) == true else { return nil }
        return value
    }

    // MARK: 状态

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let preset = initialInterviewLabel.trimmingCharacters(in: .whitespaces)
        kind = initialKind ?? suggested
        if fromSchedule && kind != .written { kind = .interview }
        if !nextKinds.contains(kind) && !endKinds.contains(kind) { kind = suggested }
        if fromSchedule {
            windowed = initialStart == nil
            openAt = initialEnd != nil ? initialStart : nil
            deadline = initialEnd
            startAt = initialStart
            if let initialStart, let initialEnd, initialEnd > initialStart { minutes = String(Int((initialEnd.timeIntervalSince(initialStart) / 60).rounded())) }
        }
        writtenType = Self.writtenLabels.contains { $0.0 == initialWrittenType } ? initialWrittenType : "written_test"
        let presetRound = (Self.rounds.firstIndex(of: preset) ?? -1) + 1
        interviewType = preset == "HR 面" ? "hr" : "interview"
        round = presetRound > 0 ? String(presetRound) : !preset.isEmpty && preset != "HR 面" ? "custom" : nextRound <= 3 ? String(nextRound) : "custom"
        customName = !preset.isEmpty && presetRound == 0 && preset != "HR 面" ? preset : "第 \(nextRound) 面"
    }

    private func choose(_ item: Kind) { kind = item; undecided = false; error = nil }

    /// 换岗位：轮次按新岗位重排；还没保存过阶段时换一个请求号，避免把上一个岗位的重试合到这个岗位上。
    private func pick(_ option: JSONValue) {
        guard option.text("id") != application.text("id") else { return }
        pickedID = option.text("id")
        if savedStage == nil { ids.stage = UUID().uuidString.lowercased(); ids.session = UUID().uuidString.lowercased() }
        let next = Self.nextRound(option)
        round = next <= 3 ? String(next) : "custom"
        customName = "第 \(next) 面"
        error = nil
    }

    // MARK: 保存

    private func lock(_ value: JSONValue?) -> JSONValue { .number(Double(value?["lock_version"]?.integer ?? application["lock_version"]?.integer ?? 0)) }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func day(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        let parts = Beijing.calendar.dateComponents([.year, .month, .day], from: date)
        return .string(String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    }
    private func trimmed(_ text: String) -> JSONValue { text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue.map(JSONValue.string) ?? .null }
    private var appID: String { application.text("id") }

    private func addStage(_ fields: [String: JSONValue]) async throws -> JSONValue {
        if let savedStage { return savedStage }
        var body = fields
        body["client_request_id"] = .string(ids.stage)
        body["base_lock_version"] = lock(nil)
        let result = try await api.careerRequest(path: "/api/job-applications/\(appID)/stages", method: "POST", query: [:], body: .object(body))
        let stage = result["application"] ?? .null
        savedStage = stage
        return stage
    }

    private func schedule(_ stage: JSONValue, type: String, roundNo: Int?, label: String, start: Date, end: Date, kind scheduleKind: String, mode: String) async throws -> JSONValue {
        let place = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: JSONValue] = [
            "client_request_id": .string(ids.session), "application_stage_id": stage["current_stage"]?["id"] ?? .null,
            "stage_type": .string(type), "round_no": roundNo.map { .number(Double($0)) } ?? .null, "stage_label": .string(label),
            "start_at": .string(iso(start)), "end_at": .string(iso(end)), "schedule_kind": .string(scheduleKind), "timezone": .string(Beijing.identifier),
            "mode": .string(mode), "meeting_url": mode == "onsite" || place.isEmpty ? .null : .string(place), "location": mode == "onsite" && !place.isEmpty ? .string(place) : .null,
            "preparation_note": trimmed(prepNote),
        ]
        if type != "other", let name = interviewer.trimmingCharacters(in: .whitespaces).nonEmptyValue { body["interviewer_name"] = .string(name) }
        return try await api.careerRequest(path: "/api/job-applications/\(appID)/interview-sessions", method: "POST", query: [:], body: .object(body))
    }

    private func save() async {
        guard !busy else { return }
        error = nil; busy = true; defer { busy = false }
        do {
            switch kind {
            case .written: try await saveWritten()
            case .interview: try await saveInterview()
            case .oc: try await saveOc()
            case .offer: try await saveOffer()
            case .rejected, .withdraw: try await saveEnd()
            }
        } catch {
            if case APIError.server(let status, _) = error, [400, 409, 422].contains(status), savedStage == nil {
                ids.stage = UUID().uuidString.lowercased()
            }
            self.error = CareerErrors.message(error)
        }
    }

    private func saveWritten() async throws {
        let duration = Int(minutes) ?? 0
        if !undecided {
            if windowed && deadline == nil { error = "请选择截止时间。"; return }
            if windowed, let deadline, deadline <= (openAt ?? Date()) { error = "截止时间必须晚于可开始作答时间。"; return }
            if !windowed && startAt == nil { error = "请选择开始时间。"; return }
            if !windowed && duration <= 0 { error = "持续时长必须大于 0 分钟。"; return }
            if windowed, let planAt, let deadline, planAt < (openAt ?? .distantPast) || planAt.addingTimeInterval(Double(Int(planMinutes) ?? 0) * 60) > deadline {
                error = "作答计划必须完整落在官方作答时段内。"; return
            }
        }
        let stage = try await addStage(["stage_type": .string(writtenType)])
        if undecided { completed(nil); return }
        do {
            let start = windowed ? openAt ?? Date() : startAt!
            let created = try await schedule(stage, type: "other", roundNo: nil, label: stage["current_stage"]?.text("stage_label").nonEmptyValue ?? writtenName, start: start,
                                             end: windowed ? deadline! : start.addingTimeInterval(Double(duration) * 60), kind: windowed ? "open_window" : "fixed_slot", mode: "video")
            if windowed, let planAt, let session = created["session"] {
                do {
                    _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/answer-plan", method: "PUT", query: [:],
                                                    body: .object(["answer_plan_start_at": .string(iso(planAt)), "answer_plan_end_at": .string(iso(planAt.addingTimeInterval(Double(Int(planMinutes) ?? 60) * 60))),
                                                                   "base_lock_version": session["lock_version"] ?? .number(1)]))
                } catch { completed("阶段与排期已保存，但作答计划保存失败，可在安排详情中重试。"); return }
            }
        } catch { completed("阶段已添加，但排期保存失败，可从安排时间入口重试"); return }
        completed(nil)
    }

    private func saveInterview() async throws {
        let duration = Int(minutes) ?? 0
        if interviewType == "interview" && interviewLabel.isEmpty { error = "请填写面试名称。"; return }
        if nameTaken { error = "这一轮已经加过了。"; return }
        if !undecided && startAt == nil { error = "请选择开始时间。"; return }
        if !undecided && duration <= 0 { error = "持续时长必须大于 0 分钟。"; return }
        let stage = try await addStage(interviewType == "hr" ? ["stage_type": .string("hr")]
                                       : ["stage_type": .string("interview"), "stage_label": .string(interviewLabel), "interview_round_no": .number(Double(roundNo))])
        if undecided { completed(nil); return }
        do {
            _ = try await schedule(stage, type: interviewType, roundNo: interviewType == "interview" ? roundNo : nil,
                                   label: interviewType == "hr" ? stage["current_stage"]?.text("stage_label").nonEmptyValue ?? "HR 面" : interviewLabel,
                                   start: startAt!, end: startAt!.addingTimeInterval(Double(duration) * 60), kind: "fixed_slot", mode: mode)
        } catch { completed("阶段已添加，但排期保存失败，可从安排时间入口重试"); return }
        completed(nil)
    }

    private func saveOc() async throws {
        guard let ocAt else { error = "请填写沟通时间。"; return }
        _ = try await addStage(["stage_type": .string("oc"), "oc_communicated_at": .string(iso(ocAt)), "oc_salary_text": trimmed(ocSalary),
                                "oc_start_text": trimmed(ocStart), "oc_contact": trimmed(ocContact), "oc_note": trimmed(note)])
        completed(nil)
    }

    private func saveOffer() async throws {
        let raw = salary.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let amount = raw.isEmpty ? nil : Double(raw)
        if !raw.isEmpty && (amount == nil || amount! < 0) { error = "薪资需要是数字。"; return }
        let stage = try await addStage(["stage_type": .string("offer")])
        do {
            _ = try await api.careerRequest(path: "/api/job-applications/\(appID)/offer", method: "POST", query: [:], body: .object([
                "base_lock_version": lock(stage), "received_on": day(receivedOn), "reply_due_on": day(replyDue), "start_on": day(startOn),
                "base_location": trimmed(location), "salary": amount.map(JSONValue.number) ?? .null, "salary_currency": amount != nil ? .string("CNY") : .null,
                "salary_period": amount != nil ? .string(salaryPeriod) : .null, "probation": trimmed(probation), "benefits_description": trimmed(benefits),
            ]))
        } catch { completed("已进入 Offer 阶段，但 Offer 状态保存失败，可从 Offer 信息入口重试"); return }
        completed(nil)
    }

    private func saveEnd() async throws {
        // 备注和收到通知的日期写进这条投递的备注，再结束
        var version = lock(savedNotes)
        let line = [kind == .rejected ? "没通过" : "我不继续了", kind == .rejected ? day(noticeOn).stringValue.map { "\($0) 收到通知" } : nil,
                    note.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue].compactMap { $0 }.joined(separator: " · ")
        if savedNotes == nil && (!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == .rejected && noticeOn != nil)) {
            let notes = [application.text("notes").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue, line].compactMap { $0 }.joined(separator: "\n")
            let result = try await api.careerRequest(path: "/api/job-applications/\(appID)", method: "PUT", query: [:], body: .object(["notes": .string(notes), "base_lock_version": lock(nil)]))
            savedNotes = result["application"]
            version = lock(savedNotes)
        }
        _ = try await api.careerRequest(path: "/api/job-applications/\(appID)/terminate", method: "POST", query: [:], body: .object([
            "client_request_id": .string(ids.terminate), "reason": .string(kind == .rejected ? "company_rejected" : "user_withdrew"), "base_lock_version": version,
        ]))
        completed(nil)
    }
}

// MARK: - 属性胶囊（11.01 / 11.03）

/// 11 分区「Linear 骨架」弹窗用的几个稿内颜色（07 页 84:343）。
enum CareerAdvanceStyle {
    static let crumb = Color(hex: 0xF4F5F7)
    static let blueSoft = Color(hex: 0xEEF3FC)
    static let blueText = Color(hex: 0x145ED6)
    static let infoBox = Color(hex: 0xF6F8FC)
    static let chipLine = Color(hex: 0xDED7CC)
    static let placeholder = Color(hex: 0xB4B0A8)
    static let hint = Color(hex: 0x96968F)
    static let divider = Color(hex: 0xEEF1F6)
}

/// 弹窗底部按钮：次按钮高 35 白底 12% 描边，主按钮高 36 墨黑（红色只给「记为未通过」），圆角 6、字 13 中等。
struct CareerAdvanceButtonStyle: ButtonStyle {
    enum Kind { case ghost, dark, danger }
    var kind: Kind = .ghost
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let filled = kind != .ghost
        return configuration.label
            .font(V3.sans(13, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(filled ? Color.white : V3.txt)
            .padding(.horizontal, 20).frame(height: filled ? 36 : 35)
            .background(kind == .danger ? V3.red : kind == .dark ? V3.txt : Color.white, in: shape)
            .overlay(shape.stroke(filled ? Color.clear : Color.black.opacity(0.12)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .contentShape(shape)
    }
}

enum CareerAdvanceFormat {
    /// 「10月15日 周四 14:00」。
    static func dateText(_ date: Date, time: Bool) -> String {
        let formatter = Beijing.formatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = time ? "M月d日 EEE HH:mm" : "M月d日"
        return formatter.string(from: date)
    }
}

/// 一个固定宽度的属性胶囊：填之前虚线、填了实线；点开在下方浮层里填，从不在原地展开。
struct CareerAdvanceProp<Content: View>: View {
    let icon: String
    let width: CGFloat
    let value: String?
    let placeholder: String
    var aside: (String, Bool)? = nil
    var disabled = false
    /// 填了之后显示在值前面的灰色小标签（稿：「收到 10月22日 周四」）。
    var lead: String? = nil
    @ViewBuilder var content: () -> Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            CareerAdvancePropLabel(icon: icon, text: value ?? placeholder, empty: value == nil, width: width, chevron: false, aside: aside, active: open, lead: lead)
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.6 : 1).help(value ?? "")
        .popover(isPresented: $open, arrowEdge: .bottom) { content().padding(14).frame(width: 280) }
        .accessibilityLabel(placeholder)
    }
}

struct CareerAdvancePropLabel: View {
    let icon: String
    let text: String
    let empty: Bool
    let width: CGFloat?
    let chevron: Bool
    var aside: (String, Bool)? = nil
    var active = false
    var lead: String? = nil
    /// 稿 11.01–11.07：胶囊按内容撑开（高 31、圆角 6、字 13），填之前虚线 #DED7CC、填了白底实线，展开时浅蓝底蓝描边。
    /// `width` 只在安排时间弹窗（12.01–12.03，环境 `careerPropFixedWidth`）里定宽，推进弹窗里按内容撑开。
    @Environment(\.careerPropFixedWidth) private var fixedWidth
    var body: some View {
        HStack(spacing: 6) {
            if !icon.isEmpty { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(V3.fnt) }
            if !empty, let lead { Text(lead).font(V3.sans(13)).foregroundStyle(CareerAdvanceStyle.hint).lineLimit(1).fixedSize() }
            Text(empty ? "+ " + text : text).font(V3.sans(13)).foregroundStyle(empty ? CareerAdvanceStyle.hint : V3.txt).lineLimit(1).truncationMode(.tail)
            if let aside { Text(aside.0).font(V3.sans(12, weight: .medium)).foregroundStyle(aside.1 ? V3.red : aside.0.hasPrefix("还剩") || aside.0.hasPrefix("今天") ? CareerAdvanceStyle.blueText : CareerAdvanceStyle.hint).lineLimit(1).fixedSize() }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(V3.fnt) }
        }
        .padding(.horizontal, 12).frame(height: 31)
        .frame(minWidth: fixedWidth ? width : nil, maxWidth: fixedWidth ? (width ?? 300) : 300, alignment: .leading)
        .background(active ? CareerAdvanceStyle.blueSoft : empty ? Color.clear : Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? V3.blue : CareerAdvanceStyle.chipLine, style: StrokeStyle(lineWidth: 1, dash: empty && !active ? [3, 2] : [])))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 选填的文字项：胶囊点开是一行输入，回车完成，内容实时保存。
struct CareerAdvanceTextProp: View {
    let icon: String
    let label: String
    @Binding var text: String
    let width: CGFloat
    let placeholder: String?
    let limit: Int
    @State private var open = false
    var body: some View {
        let value = text.trimmingCharacters(in: .whitespaces).nonEmptyValue
        Button { open.toggle() } label: {
            CareerAdvancePropLabel(icon: icon, text: value ?? label, empty: value == nil, width: width, chevron: false, active: open)
        }
        .buttonStyle(.plain).help(value ?? "")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                TextField(placeholder ?? "", text: $text).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit { open = false }
                    .onChange(of: text) { _, new in if new.count > limit { text = String(new.prefix(limit)) } }
                Text("回车完成").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
            }.padding(14)
        }
        .accessibilityLabel(label)
    }
}

/// 时间浮层里的一行（12.04 统一日期时间选择器）：标签和已选值在上，按时的带「时 : 分」时间框；下面是同一套月历。
struct CareerAdvanceDateRow: View {
    let label: String
    @Binding var value: Date?
    let time: Bool
    var placeholder = "选择日期"
    var clearable = false
    /// 截止日取当天 23:59。
    var endOfDay = false
    @State private var month = Date()
    @State private var clockValid = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(label).font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(width: 56, alignment: .leading)
                Text(value.map { CareerTimeFormat.day($0) } ?? placeholder).font(V3.sans(12.5)).foregroundStyle(value == nil ? V3.fnt : V3.txt)
                Spacer(minLength: 0)
                if time, value != nil { CareerClockField(value: $value, compact: true, valid: $clockValid) }
                if clearable && value != nil {
                    Button { value = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("清除\(label)")
                }
            }
            CareerMiniCalendar(month: $month, selected: value, pick: pick).frame(width: 250)
        }
        .onAppear { month = value ?? Date() }
    }
    private func pick(_ day: Date) {
        let calendar = Beijing.calendar
        if endOfDay, !time { value = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day) ?? day }
        else if !time { value = calendar.startOfDay(for: day) }
        else {
            let hour = value.map { calendar.component(.hour, from: $0) } ?? 10
            let minute = value.map { calendar.component(.minute, from: $0) } ?? 0
            value = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
    }
}

private struct CareerPropFixedWidthKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 属性格是否按调用方给的 `width` 定宽（安排时间弹窗按稿定宽）。
    var careerPropFixedWidth: Bool {
        get { self[CareerPropFixedWidthKey.self] }
        set { self[CareerPropFixedWidthKey.self] = newValue }
    }
}
