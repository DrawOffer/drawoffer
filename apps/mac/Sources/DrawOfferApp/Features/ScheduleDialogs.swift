import AppKit
import DrawOfferCore
import SwiftUI

/// 08 · 面试日程共用的颜色、格式和按钮（Figma `5:20`）。
enum ScheduleInk {
    /// 稿里的三级灰字 #96968F（标签、时间刻度、说明）。
    static let faint = Color(hex: 0x96968F)
    static let dot = Color(hex: 0xD6D6D1)
    static func format(_ date: Date, _ pattern: String) -> String {
        let f = Beijing.formatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = pattern; return f.string(from: date)
    }
}

/// 稿内弹窗按钮：36 高、圆角 7、12 号中粗字；墨黑主按钮与白底描边次按钮。
struct ScheduleButtonStyle: ButtonStyle {
    var dark = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        return configuration.label.font(V3.sans(12, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(dark ? Color.white : V3.txt)
            .padding(.horizontal, 28).frame(height: 36)
            .background {
                if dark { shape.fill(configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt) }
                else { shape.fill(configuration.isPressed ? V3.field : .white).overlay(shape.strokeBorder(V3.cl)) }
            }
            .opacity(enabled ? 1 : 0.4).contentShape(shape)
    }
}

/// 弹窗右上角 ×（稿内 7×7 图标，可点区域 22），同时承担 Esc 关闭。
struct ScheduleCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(ScheduleInk.faint).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("关闭")
    }
}

/// 状态胶囊（待面试 / 待完成 / 已完成 / 已取消）：22 高、10.5 号中粗。
struct SchedulePill: View {
    let label: String
    let foreground: Color
    let background: Color
    var height: CGFloat = 22
    var body: some View {
        Text(label).font(V3.sans(10.5, weight: .medium)).foregroundStyle(foreground).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).frame(height: height).background(background, in: Capsule())
    }
}

/// 舞台里的白色小卡（圆角 10、#E4E4E0 描边）。
private struct ScheduleArtCard<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) { content() }
            .frame(width: width, height: height, alignment: .topLeading)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(V3.cl))
    }
}

private struct ScheduleBar: View {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var color: Color = V3.line
    var radius: CGFloat = 2
    var body: some View { RoundedRectangle(cornerRadius: radius).fill(color).frame(width: w, height: h).offset(x: x, y: y) }
}

/// 日期卡（72×82）：顶部 20 高色带写月份，26 号日期，9.5 号说明。
struct ScheduleDateCard: View {
    let date: Date
    let sub: String
    let band: Color
    var faded = false
    var body: some View {
        VStack(spacing: 0) {
            Text("\(Beijing.calendar.component(.month, from: date)) 月").font(V3.sans(9.5, weight: .medium)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 20).background(band)
            Text(ScheduleInk.format(date, "dd")).font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(faded ? ScheduleInk.faint : V3.txt).frame(height: 31).padding(.top, 3)
            Text(sub).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(ScheduleInk.faint).lineLimit(1).padding(.top, 7)
            Spacer(minLength: 0)
        }
        .frame(width: 72, height: 82).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(V3.cl))
        .opacity(faded ? 0.7 : 1)
    }
}

/// 03–06 日程详情舞台（456×128）：日期卡 + 场景卡；作答窗口是一张时段进度卡。
struct ScheduleStageArt: View {
    enum Kind { case video, onsite, ai, exam, window, test, done, cancel }
    let kind: Kind
    let item: ScheduledInterview
    var band: Color = V3.blue
    var planStart: Date? = nil
    var meInitial = "我"
    var resultChip: (String, Color, Color) = ("等结果", ScheduleInk.faint, V3.field)

    private var dateSub: String {
        kind == .window || kind == .test ? ScheduleInk.format(item.end, "HH:mm") + " 截止" : ScheduleInk.format(item.start, "EEE HH:mm")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch kind {
            case .window: windowCard.offset(x: 48, y: 24)
            case .cancel:
                ScheduleDateCard(date: item.start, sub: ScheduleInk.format(item.start, "EEE HH:mm"), band: ScheduleInk.faint, faded: true).offset(x: 192, y: 23)
                RoundedRectangle(cornerRadius: 0.75).fill(ScheduleInk.faint).frame(width: 80, height: 2).offset(x: 188, y: 63)
                badge { Rectangle().fill(ScheduleInk.faint).frame(width: 7, height: 1.5) }.offset(x: 252, y: 17)
            case .done:
                ScheduleDateCard(date: item.start, sub: dateSub, band: band).offset(x: 96, y: 23)
                Circle().fill(V3.green).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)).offset(x: 158, y: 17)
                ScheduleArtCard(width: 150, height: 60) {
                    Text(item.label + "结果").font(V3.sans(10, weight: .medium)).foregroundStyle(ScheduleInk.faint).offset(x: 14, y: 11)
                    SchedulePill(label: resultChip.0, foreground: resultChip.1, background: resultChip.2, height: 20).offset(x: 14, y: 30)
                    ScheduleBar(x: 80, y: 38, w: 54, h: 4)
                }.offset(x: 210, y: 34)
            default:
                ScheduleDateCard(date: item.start, sub: dateSub, band: band).offset(x: 96, y: 23)
                ScheduleArtCard(width: 168, height: 88) { scene }.offset(x: 192, y: 20)
            }
        }
        .frame(width: 456, height: 128, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Circle().fill(.white).frame(width: 22, height: 22).overlay(Circle().strokeBorder(V3.cl)).overlay(content())
    }

    @ViewBuilder private var scene: some View {
        switch kind {
        case .video:
            // 视频通话：两格画面 + 底部控制条
            let other = String(item.raw.text("interviewer_name").prefix(1))
            tile(other.isEmpty ? "面" : other, dark: false).offset(x: 10, y: 22)
            tile(meInitial, dark: true).offset(x: 88, y: 22)
            HStack(spacing: 4) {
                Circle().fill(V3.sk2).frame(width: 6, height: 6); Circle().fill(V3.sk2).frame(width: 6, height: 6)
                Capsule().fill(V3.red).frame(width: 18, height: 6)
            }.frame(width: 60, height: 10).offset(x: 54, y: 72)
        case .onsite:
            // 现场：简化地图 + 地点标签
            Color(hex: 0xEFEFEC)
            ScheduleBar(x: 14, y: 10, w: 34, h: 16, color: Color(hex: 0xE3E3DF), radius: 3)
            ScheduleBar(x: 112, y: 10, w: 44, h: 14, color: Color(hex: 0xE3E3DF), radius: 3)
            ScheduleBar(x: 14, y: 46, w: 30, h: 12, color: Color(hex: 0xE3E3DF), radius: 3)
            ScheduleBar(x: 128, y: 48, w: 30, h: 28, color: Color(hex: 0xE3E3DF), radius: 3)
            Rectangle().fill(.white).frame(width: 6, height: 88).offset(x: 56)
            Rectangle().fill(.white).frame(width: 6, height: 88).offset(x: 118)
            Rectangle().fill(.white).frame(width: 168, height: 6).offset(y: 34)
            Circle().fill(V3.txt).frame(width: 20, height: 20)
                .overlay(Image(systemName: "mappin").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)).offset(x: 80, y: 30)
            let place = String(item.raw.text("location").split(separator: " ").last.map(String.init)?.suffix(8) ?? "现场")
            Text(place.isEmpty ? "现场" : place).font(V3.sans(8.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 16).background(.white, in: Capsule()).overlay(Capsule().strokeBorder(V3.cl))
                .frame(width: 168).offset(y: 58)
        case .ai:
            // AI 面试：头像 + 声纹（不用 Sparkles 图标）
            Circle().fill(V3.txt).frame(width: 36, height: 36)
                .overlay(Text("AI").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)).offset(x: 14, y: 16)
            ForEach(Array([6, 12, 20, 14, 24, 10, 18, 8, 14, 22, 12, 6].enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 2).fill(index < 7 ? V3.txt : V3.sk2).frame(width: 4, height: CGFloat(height))
                    .offset(x: 62 + CGFloat(index) * 8, y: 34 - CGFloat(height) / 2)
            }
            ScheduleBar(x: 14, y: 64, w: 120, h: 4)
            ScheduleBar(x: 14, y: 74, w: 84, h: 4)
        case .exam:
            // 笔试：题目勾选 + 计时角标
            ScheduleBar(x: 14, y: 12, w: 56, h: 6, color: V3.txt)
            ScheduleBar(x: 14, y: 22, w: 86, h: 4, color: V3.sk2)
            RoundedRectangle(cornerRadius: 3).fill(V3.txt).frame(width: 10, height: 10)
                .overlay(Image(systemName: "checkmark").font(.system(size: 6, weight: .bold)).foregroundStyle(.white)).offset(x: 14, y: 38)
            ScheduleBar(x: 30, y: 41, w: 112, h: 4)
            ForEach([55, 71], id: \.self) { y in
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color(hex: 0xE9E9E5)).frame(width: 9, height: 9).offset(x: 15, y: CGFloat(y))
            }
            ScheduleBar(x: 30, y: 57, w: 92, h: 4)
            ScheduleBar(x: 30, y: 73, w: 112, h: 4)
            badge { Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(V3.sub) }.offset(x: 136, y: 10)
        case .test:
            // 测评：量表题
            ScheduleBar(x: 14, y: 14, w: 108, h: 5, color: V3.txt)
            ScheduleBar(x: 14, y: 24, w: 72, h: 4, color: V3.sk2)
            ForEach(0..<5, id: \.self) { index in
                Group {
                    if index == 3 { Circle().fill(V3.txt) } else { Circle().strokeBorder(V3.cl, lineWidth: 1) }
                }.frame(width: 10, height: 10).offset(x: 16 + CGFloat(index) * 25, y: 40)
            }
            Text("不符合").font(V3.sans(8.5)).foregroundStyle(ScheduleInk.faint).offset(x: 14, y: 64)
            Text("很符合").font(V3.sans(8.5)).foregroundStyle(ScheduleInk.faint).offset(x: 128, y: 64)
        default: EmptyView()
        }
    }

    private func tile(_ initial: String, dark: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(V3.field).frame(width: 70, height: 44)
            .overlay(Circle().fill(dark ? V3.txt : V3.sk2).frame(width: 22, height: 22)
                .overlay(Text(initial).font(V3.sans(9.5, weight: .medium)).foregroundStyle(dark ? .white : V3.sub)))
    }

    /// 05.02 作答窗口：官方时段进度条，标出今天和我的计划。
    private var windowCard: some View {
        let total = max(1, item.end.timeIntervalSince(item.start))
        let today = min(1, max(0, Date().timeIntervalSince(item.start) / total))
        let plan = planStart.map { min(1, max(0, $0.timeIntervalSince(item.start) / total)) }
        let left = item.end > Date() ? "还剩 \(max(1, Int((item.end.timeIntervalSinceNow / 86400).rounded(.up)))) 天" : "已截止"
        return ScheduleArtCard(width: 360, height: 80) {
            Text("官方时段").font(V3.sans(10, weight: .medium)).foregroundStyle(ScheduleInk.faint).offset(x: 20, y: 12)
            Text(left).font(V3.sans(10, weight: .medium)).foregroundStyle(V3.orange).frame(width: 320, alignment: .trailing).offset(x: 20, y: 12)
            ScheduleBar(x: 20, y: 40, w: 320, h: 6, color: V3.sk2, radius: 3)
            ScheduleBar(x: 20, y: 40, w: 320 * today, h: 6, color: Color(hex: 0xE9E9E5), radius: 3)
            RoundedRectangle(cornerRadius: 0.75).fill(V3.orange).frame(width: 2, height: 16).offset(x: 19 + 320 * today, y: 35)
            if let plan { RoundedRectangle(cornerRadius: 4).fill(V3.txt).frame(width: 12, height: 12).offset(x: 14 + 320 * plan, y: 37) }
            Text(ScheduleInk.format(item.start, "MM-dd") + " 开放").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(ScheduleInk.faint).offset(x: 20, y: 55)
            Text(ScheduleInk.format(item.end, "MM-dd") + " 截止").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(ScheduleInk.faint).frame(width: 320, alignment: .trailing).offset(x: 20, y: 55)
            if today > 0.08 && today < 0.92 {
                Text("今天").font(V3.sans(9.5, weight: .medium)).foregroundStyle(V3.orange).frame(width: 40).offset(x: 20 + 320 * today - 20, y: 56)
            }
            if let plan, plan > 0.1, plan < 0.9, abs(plan - today) > 0.08 {
                Text("我的计划").font(V3.sans(9.5, weight: .medium)).foregroundStyle(V3.txt).fixedSize().frame(width: 60).offset(x: 20 + 320 * plan - 30, y: 56)
            }
        }
    }
}

// MARK: - 03–06 日程详情

/// 03.01–06.02 日程详情弹窗（520 宽）：衬线标题 + 状态胶囊、场景舞台、信息卡、作答计划与说明、底部按钮行。
struct ScheduleDetailDialog: View {
    let interview: ScheduledInterview
    let api: any APIClient
    var meInitial = "我"
    let close: () -> Void
    let changed: () -> Void
    let openRecord: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var item: ScheduledInterview?
    @State private var planSet = false
    @State private var planStart = Date()
    @State private var planMinutes = 120
    @State private var planPicker = false
    @State private var busy = false
    @State private var error: String?
    private var current: ScheduledInterview { item ?? interview }
    private var isWindow: Bool { current.openWindow }
    private var stage: String { current.label }
    private var isExam: Bool { stage.contains("笔试") || current.raw.text("stage_type") == "written_test" }
    private var isTest: Bool { stage.contains("测评") || current.raw.text("stage_type") == "assessment" }
    private var isAI: Bool { stage.lowercased().contains("ai") || current.raw.text("stage_type") == "ai_interview" }
    private var isInterview: Bool { !isExam && !isTest && !isAI }
    private var onsite: Bool { current.raw.text("mode") == "onsite" }
    private var cancelled: Bool { current.raw.text("status") == "cancelled" }
    private var completed: Bool { current.raw.text("status") == "completed" }
    private var active: Bool { !cancelled && !completed && current.start <= Date() && current.end > Date() }
    private var canEdit: Bool { current.editable }
    private var status: (String, Color, Color) {
        if completed { return ("已完成", V3.green, V3.greenSoft) }
        if cancelled { return ("已取消", ScheduleInk.faint, V3.field) }
        if isWindow { return ("待完成", V3.orange, V3.orangeSoft) }
        if active { return ("进行中", V3.blue, V3.blueSoft) }
        return (isExam || isAI ? "待参加" : "待面试", V3.blue, V3.blueSoft)
    }
    private var result: (String, Color, Color) {
        switch current.raw.text("round_result") {
        case "passed": return ("已通过", V3.green, V3.greenSoft)
        case "rejected": return ("未通过", V3.red, V3.redSoft)
        default: return ("等结果", ScheduleInk.faint, V3.field)
        }
    }
    private var kind: ScheduleStageArt.Kind {
        if cancelled { return .cancel }
        if completed { return .done }
        if isWindow { return isTest ? .test : .window }
        return isAI ? .ai : isExam ? .exam : isTest ? .test : onsite ? .onsite : .video
    }
    /// 标题下一行：岗位 · 倒计时 / 准点开始 / N 天前 / 截止前任选时间完成。
    private var relative: String {
        if cancelled { return "" }
        if completed {
            let days = Int(Date().timeIntervalSince(current.end) / 86400)
            return days >= 1 ? " · \(days) 天前" : ""
        }
        if isWindow { return " · 截止前任选时间完成" }
        let until = current.start.timeIntervalSinceNow
        guard until > 0 else { return "" }
        if !isInterview { return " · 准点开始" }
        return until < 86400 ? " · 还有 \(Int(until / 3600)) 小时 \(Int(until.truncatingRemainder(dividingBy: 3600) / 60)) 分" : " · \(Int((until / 86400).rounded(.up))) 天后"
    }
    private var meetingText: String { current.raw.text("meeting_url") }
    private var meetingURL: URL? {
        let text = meetingText.contains("://") ? meetingText : "https://" + meetingText
        return meetingText.isEmpty ? nil : URL(string: text).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }
    private var platform: String? {
        let url = meetingText
        if url.contains("feishu.cn") || url.contains("larksuite.com") { return "飞书" }
        if url.contains("meeting.tencent.com") { return "腾讯会议" }
        if url.contains("nowcoder.com") { return "牛客网" }
        if url.contains("beisen") || url.contains("italent") { return "北森测评" }
        return nil
    }
    /// 「形式」：视频面试 · 飞书 / 线上 · 牛客网 · 90 分钟 / 线上 · AI 面试官。
    private var modeText: String {
        if isAI { return "线上 · AI 面试官" }
        if !isInterview {
            var parts = ["线上"]; if let platform { parts.append(platform) }
            if isExam && !isWindow { parts.append("\(max(1, Int(current.end.timeIntervalSince(current.start) / 60))) 分钟") }
            return parts.joined(separator: " · ")
        }
        let base = ["video": "视频面试", "onsite": "现场面试", "phone": "电话面试"][current.raw.text("mode")] ?? "其他方式"
        return [base, cancelled ? nil : platform].compactMap { $0 }.joined(separator: " · ")
    }
    private var linkLabel: String { isAI ? "面试链接" : isExam ? "笔试链接" : isTest ? "测评链接" : "会议链接" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(current.company + " · " + stage).font(V3.serif(20)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 29)
                    SchedulePill(label: status.0, foreground: status.1, background: status.2)
                    Spacer(minLength: 0)
                }
                Text(current.title + relative).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(1).frame(height: 15).padding(.top, 2)
                V3DotStage(height: 128) {
                    ScheduleStageArt(kind: kind, item: current, band: cancelled ? ScheduleInk.faint : InterviewScheduleView.color(current, month: true),
                                     planStart: planSet ? planStart : nil, meInitial: meInitial, resultChip: result)
                }
                .overlay(alignment: .bottomTrailing) { if busy && item == nil { ProgressView().controlSize(.small).padding(8) } }
                .padding(.top, 19)
                rows.padding(.top, 21)
                if isWindow { planSection.padding(.top, 12) }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, entry in note(entry.0, tone: entry.1) }
                if let error { Text(error).font(V3.sans(11.5)).foregroundStyle(V3.red).padding(.top, 10) }
            }
            .padding(.horizontal, 32).padding(.top, 31).padding(.bottom, 32)
            HStack(spacing: 10) {
                if primary != nil || (isWindow && canEdit) {
                    Button { openRecord() } label: {
                        HStack(spacing: 6) { Text("查看求职记录"); Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium)) }
                            .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if isWindow && canEdit && !current.raw.text("answer_plan_start_at").isEmpty {
                    Button("清除计划") { Task { await savePlan(clear: true) } }.buttonStyle(ScheduleButtonStyle()).disabled(busy)
                }
                Button("关闭", action: close).buttonStyle(ScheduleButtonStyle())
                if let primary {
                    Button(primary.0) { primary.1() }.buttonStyle(ScheduleButtonStyle(dark: true)).disabled(busy)
                } else {
                    Button("查看求职记录") { openRecord() }.buttonStyle(ScheduleButtonStyle(dark: true))
                }
            }
            .padding(.horizontal, 32).frame(height: 88)
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        .frame(width: 520)
        .overlay(alignment: .topTrailing) { ScheduleCloseButton(action: close).padding(.top, 22).padding(.trailing, 24) }
        .task {
            if let start = CareerApplication.date(interview.raw.text("answer_plan_start_at")) {
                planSet = true; planStart = start
                if let end = CareerApplication.date(interview.raw.text("answer_plan_end_at")) { planMinutes = max(1, Int(end.timeIntervalSince(start) / 60)) }
            } else { planStart = max(interview.start, Date()) }
            busy = true
            do {
                let data = try await api.careerRequest(path: "/api/interview-sessions/\(interview.id)", method: "GET", query: [:], body: nil)
                try Task.checkCancellation()
                item = ScheduledInterview(data["session"] ?? .null)
            } catch { /* 列表里的副本继续显示 */ }
            busy = false
        }
    }

    private var primary: (String, () -> Void)? {
        guard !cancelled && !completed else { return nil }
        if isWindow && canEdit { return ("保存作答计划", { Task { await savePlan(clear: false) } }) }
        if let meetingURL { return (isExam ? "进入笔试" : isTest ? "进入测评" : isAI ? "进入 AI 面试" : "进入会议", { openURL(meetingURL) }) }
        return nil
    }

    private var notes: [(String, Color)] {
        var list: [(String, Color)] = []
        if !isWindow && completed { list.append(("复盘写在求职记录里，这一场不能再拖动改期。", V3.green)) }
        if !isWindow && onsite && isInterview && !completed && !cancelled { list.append(("现场面试没有会议链接，地点和时间都在求职记录里改。", V3.fnt)) }
        if !isWindow && isAI && !completed && !cancelled { list.append(("AI 面试只能按时参加，请在开始时间进入。", V3.fnt)) }
        if isWindow && canEdit && !planSet && current.end > Date() {
            list.append(("还剩 \(max(1, Int((current.end.timeIntervalSinceNow / 86400).rounded(.up)))) 天，还没安排作答时间。", V3.orange))
        }
        return list
    }

    // 信息卡：每行 46 高，图标 + 12 号灰标签，右侧 12.5 号值
    private enum Tone { case strong, normal, soft, muted, link, result }
    private var rows: some View {
        let interviewer = [current.raw.text("interviewer_name"), current.raw.text("interviewer_title")].filter { !$0.isEmpty }
        let person = interviewer.count == 2 ? "\(interviewer[1]) \(interviewer[0])" : interviewer.first ?? ""
        let location = current.raw.text("location")
        let base: Tone = completed ? .soft : cancelled ? .muted : .normal
        var list: [(String, String, String, Tone)] = [
            isWindow ? ("calendar", "官方时段", ScheduleInk.format(current.start, "MM-dd HH:mm") + " – " + ScheduleInk.format(current.end, "MM-dd HH:mm"), completed || cancelled ? base : .strong)
                : ("clock", cancelled ? "原定时间" : "时间", ScheduleInk.format(current.start, "MM-dd EEE HH:mm") + " – " + ScheduleInk.format(current.end, "HH:mm"), completed || cancelled ? base : .strong),
        ]
        if completed {
            if !location.isEmpty { list.append(("mappin.and.ellipse", "地点", location, base)) } else { list.append(("play.fill", "形式", modeText, base)) }
            list.append(("flag", "结果", result.0, .result))
        } else {
            if isInterview && !cancelled { list.append(("person", "面试官", person.isEmpty ? "未填写" : person, person.isEmpty ? .muted : base)) }
            else if !isInterview && !cancelled && !person.isEmpty { list.append(("person", "联系人", person, base)) }
            if onsite && isInterview && !cancelled { list.append(("mappin.and.ellipse", "地点", location.isEmpty ? "未填写" : location, location.isEmpty ? .muted : base)) }
            else { list.append(("play.fill", "形式", modeText, base)) }
            if !meetingText.isEmpty && !cancelled { list.append(("link", linkLabel, meetingText, .link)) }
            // 准备清单：未结束的日程有清单时显示进度
            let prepTotal = current.raw["prep_total"]?.integer ?? 0
            if !cancelled && prepTotal > 0 {
                let prepDone = current.raw["prep_done"]?.integer ?? 0
                list.append(("checklist", "准备清单", prepDone >= prepTotal ? "\(prepDone)/\(prepTotal) 已备好" : "\(prepDone)/\(prepTotal) 已完成", .normal))
            }
            if cancelled && !current.raw.text("cancellation_reason").isEmpty { list.append(("text.alignleft", "取消原因", current.raw.text("cancellation_reason"), .normal)) }
        }
        return VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(V3.line).frame(height: 1).padding(.horizontal, 17) }
                HStack(spacing: 0) {
                    Image(systemName: row.0).font(.system(size: row.0 == "play.fill" ? 7 : 10)).foregroundStyle(ScheduleInk.faint).frame(width: 12)
                    Text(row.1).font(V3.sans(12)).foregroundStyle(ScheduleInk.faint).padding(.leading, 10)
                    Spacer(minLength: 12)
                    value(row.2, tone: row.3)
                }.padding(.leading, 18).padding(.trailing, 18).frame(height: 46)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(V3.cl))
    }
    @ViewBuilder private func value(_ text: String, tone: Tone) -> some View {
        switch tone {
        case .link:
            Button { if let meetingURL { openURL(meetingURL) } } label: {
                HStack(spacing: 6) {
                    Text(text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "link").font(.system(size: 8, weight: .medium))
                }.font(.system(size: 12.5)).foregroundStyle(V3.blue).contentShape(Rectangle())
            }.buttonStyle(.plain).help(text)
        case .result:
            SchedulePill(label: text, foreground: result.1, background: result.2, height: 20)
        default:
            Text(text).font(V3.sans(12.5, weight: tone == .strong ? .medium : .regular))
                .foregroundStyle(tone == .soft ? V3.sub : tone == .muted ? ScheduleInk.faint : V3.txt).lineLimit(1).textSelection(.enabled)
        }
    }

    /// 05.02 / 05.03 我的作答计划：开始时间（292 宽）+ 时长（148 宽），各 40 高。
    private var planSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("我的作答计划").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt)
                Spacer()
                Text("选填 · 仅提醒自己，不改官方时间").font(V3.sans(10.5)).foregroundStyle(ScheduleInk.faint)
            }.frame(height: 14)
            HStack(spacing: 16) {
                Button { if canEdit { planPicker = true } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(V3.sub)
                        Text(planSet ? ScheduleInk.format(planStart, "MM-dd HH:mm") : canEdit ? "选择开始日期和时间" : "未安排")
                            .font(planSet ? .system(size: 13).monospacedDigit() : V3.sans(13)).foregroundStyle(planSet || canEdit ? V3.txt : ScheduleInk.faint)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 40).frame(maxWidth: .infinity)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(V3.cl))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!canEdit).accessibilityLabel("计划作答时间")
                .popover(isPresented: $planPicker, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        DatePicker("计划作答时间", selection: Binding(get: { planStart }, set: { planStart = $0; planSet = true; error = nil }),
                                   in: current.start...max(current.start, current.end), displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical).labelsHidden()
                        HStack { Spacer(); Button("完成") { planSet = true; planPicker = false }.buttonStyle(ScheduleButtonStyle(dark: true)) }
                    }.padding(16).frame(width: 320)
                }
                Menu {
                    ForEach(Array(Set([30, 45, 60, 90, 120, 180, planMinutes])).sorted(), id: \.self) { minutes in
                        Button("\(minutes) 分钟") { planMinutes = minutes; error = nil }
                    }
                } label: {
                    HStack(spacing: 0) {
                        Text("时长").font(V3.sans(11)).foregroundStyle(ScheduleInk.faint)
                        Spacer(minLength: 4)
                        Text("\(planMinutes)").font(.system(size: 13).monospacedDigit()).foregroundStyle(V3.txt)
                        Spacer(minLength: 4)
                        Text("分钟").font(V3.sans(11)).foregroundStyle(ScheduleInk.faint)
                    }
                    .padding(.horizontal, 14).frame(width: 148, height: 40)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(V3.cl))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(!canEdit).accessibilityLabel("作答时长")
            }
        }
    }
    private func note(_ text: String, tone: Color) -> some View {
        HStack(spacing: 8) { Circle().fill(tone).frame(width: 6, height: 6); Text(text).font(V3.sans(11.5)).foregroundStyle(V3.sub) }.padding(.top, 16)
    }
    private func savePlan(clear: Bool) async {
        guard canEdit, !busy else { return }
        if !clear && !planSet { error = "先选择计划作答的开始时间。"; return }
        let end = planStart.addingTimeInterval(Double(planMinutes) * 60)
        if !clear && (planStart < current.start || end > current.end) { error = "作答计划必须完整落在官方开放时间内。"; return }
        busy = true; error = nil
        do {
            let f = ISO8601DateFormatter()
            let body: JSONValue = .object(["base_lock_version": current.raw["lock_version"] ?? .number(1),
                                           "answer_plan_start_at": clear ? .null : .string(f.string(from: planStart)),
                                           "answer_plan_end_at": clear ? .null : .string(f.string(from: end))])
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(current.id)/answer-plan", method: "PUT", query: [:], body: body)
            changed()
        } catch {
            if case APIError.server(let status, let code) = error { self.error = status == 409 ? "记录已更新，请关闭后刷新再试（\(code)）。" : "保存失败（\(code)）。" }
            else { self.error = "连接失败，作答计划尚未确认保存。" }
        }
        busy = false
    }
}

// MARK: - 02.01 新建面试 · 没有可推进的流程

/// 02.01：没有可以直接加一场的流程时，说明原因、列出被排除的流程（去投递 / 查看），主按钮「新建求职流程」带着选中的时间。
struct ScheduleNoStageDialog: View {
    let start: Date
    let end: Date
    let excluded: [CareerApplication]
    let close: () -> Void
    let createProcess: () -> Void
    let openRecord: (CareerApplication) -> Void

    /// `stageBlockReason`：各差哪一步。
    static func block(_ item: CareerApplication) -> (reason: String, action: String, tone: Color) {
        let projection = CareerBoard.projection(item.raw)
        if projection.column == "pending" { return ("\(projection.stageLabel) · 先在看板里标记投递", "去投递", ScheduleInk.faint) }
        if item.raw.text("current_stage_type") == "offer" || item.stage == "offer" { return ("已进入 Offer · 不再安排面试", "查看", V3.green) }
        if item.raw.text("stage_state") == "scheduled" {
            let date = CareerApplication.date(item.raw.text("next_session_start_at")).map { " " + ScheduleInk.format($0, "MM-dd") } ?? ""
            return ("\(projection.stageLabel)\(date) 已安排 · 先完成这一轮", "查看", V3.blue)
        }
        return ("\(projection.stageLabel) · \(projection.statusLabel)", "查看", V3.blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("新建面试").font(V3.serif(20)).foregroundStyle(V3.txt).frame(height: 29)
                Text(ScheduleInk.format(start, "EEE MM-dd · HH:mm") + " – " + ScheduleInk.format(end, "HH:mm"))
                    .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(V3.sub).frame(height: 15).padding(.top, 2)
                V3DotStage(height: 120) { art }.padding(.top, 19)
                Text("还没有可以安排下一场的求职流程").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).frame(height: 18).padding(.top, 20)
                Text("只有已经投递、上一阶段已经结束的流程能在这里直接加一场。收到新岗位的面试通知？新建一个求职流程，这个时间会一起带过去。")
                    .font(V3.sans(12)).foregroundStyle(V3.sub).lineHeight(12, 20).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                if !excluded.isEmpty {
                    Text("这些流程现在还不能加").font(V3.sans(11, weight: .medium)).foregroundStyle(ScheduleInk.faint).frame(height: 13).padding(.top, 23)
                    VStack(spacing: 0) {
                        ForEach(Array(excluded.prefix(4).enumerated()), id: \.element.id) { index, item in
                            let block = Self.block(item)
                            if index > 0 { Rectangle().fill(V3.line).frame(height: 1).padding(.horizontal, 17) }
                            HStack(spacing: 0) {
                                Circle().fill(block.tone).frame(width: 6, height: 6).padding(.trailing, 11)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.company + " · " + item.title).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                                    Text(block.reason).font(V3.sans(11)).foregroundStyle(ScheduleInk.faint).lineLimit(1)
                                }
                                Spacer(minLength: 12)
                                Button { openRecord(item) } label: {
                                    HStack(spacing: 8) { Text(block.action); Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
                                        .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }.padding(.leading, 14).padding(.trailing, 22).frame(height: 52)
                        }
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(V3.cl))
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 32).padding(.top, 31).padding(.bottom, 34)
            HStack {
                Button("取消", action: close).buttonStyle(.plain).font(V3.sans(11.5)).foregroundStyle(ScheduleInk.faint)
                Spacer()
                Button("新建求职流程", action: createProcess).buttonStyle(ScheduleButtonStyle(dark: true)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32).frame(height: 88)
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        .frame(width: 560)
        .overlay(alignment: .topTrailing) { ScheduleCloseButton(action: close).padding(.top, 22).padding(.trailing, 24) }
    }

    /// 舞台：带时间的事件卡 + 问号，右侧三列看板（待投递 / 等待结果 / Offer）。
    private var art: some View {
        ZStack(alignment: .topLeading) {
            ScheduleArtCard(width: 111, height: 63) {
                ScheduleBar(x: 9, y: 11, w: 40, h: 5, color: V3.sk2)
                ScheduleBar(x: 9, y: 23, w: 64, h: 4)
                Text(ScheduleInk.format(start, "HH:mm") + " – " + ScheduleInk.format(end, "HH:mm")).font(.system(size: 7.5).monospacedDigit()).foregroundStyle(ScheduleInk.faint)
                    .padding(.horizontal, 5).frame(height: 14).background(V3.field, in: RoundedRectangle(cornerRadius: 3)).offset(x: 9, y: 39)
            }.offset(x: 99, y: 27)
            Circle().fill(.white).frame(width: 24, height: 24).overlay(Circle().strokeBorder(V3.cl))
                .overlay(Text("?").font(.system(size: 12, weight: .semibold)).foregroundStyle(V3.sub)).offset(x: 198, y: 46)
            ForEach(Array(["待投递", "等待结果", "Offer"].enumerated()), id: \.offset) { index, label in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 5.5).fill(Color(hex: 0xFBFBFA)).overlay(RoundedRectangle(cornerRadius: 5.5).strokeBorder(V3.line))
                    Text(label).font(V3.sans(8, weight: .medium)).foregroundStyle(ScheduleInk.faint).padding(.top, 5)
                    VStack(spacing: 7) {
                        if index < 2 { miniCard; miniCard }
                        else { RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color(hex: 0xE9E9E5), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 43, height: 23) }
                    }.padding(.top, 24)
                }.frame(width: 51, height: 83).offset(x: 243 + CGFloat(index) * 58, y: 19)
            }
        }
        .frame(width: 496, height: 120, alignment: .topLeading)
        .accessibilityHidden(true)
    }
    private var miniCard: some View {
        RoundedRectangle(cornerRadius: 3.5).fill(.white).overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Color(hex: 0xE9E9E5)))
            .overlay(alignment: .topLeading) { VStack(alignment: .leading, spacing: 4) { Capsule().fill(V3.sk2).frame(width: 22, height: 3); Capsule().fill(V3.line).frame(width: 30, height: 3) }.padding(6) }
            .frame(width: 43, height: 23)
    }
}
