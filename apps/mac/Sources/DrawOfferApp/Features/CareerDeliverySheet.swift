import DrawOfferCore
import SwiftUI

/// Figma 07 页 09.09「补充投递信息」（Web `DeliveryDialog`）：投递详情 ⋯ 菜单「编辑投递信息」打开。
/// 只改这条投递本身：投递日期、渠道、投递简历、投递备注；不加阶段、不动进度。
/// 稿：600 宽，左右 33；头部 44 图标块 + 衬线标题 22 + 一行「公司 · 岗位」和蓝色阶段胶囊；
/// 两列字段各 260、间距 16，输入框 39 高；投递简历一行 59 高（PDF 角标 + 名称 + 「更换」）；「补充 + 投递备注」；底部细线 + 取消 / 保存。
struct CareerDeliverySheet: View {
    let application: JSONValue
    let stageLabel: String
    let api: any APIClient
    let close: () -> Void
    let saved: () -> Void

    static let channels = CareerRecordApplied.channels

    @State private var appliedAt: Date?
    @State private var channel = ""
    @State private var resumeID: String?
    @State private var notes = ""
    @State private var showNotes = false
    @State private var resumes: [JSONValue]?
    @State private var picking = false
    @State private var dateOpen = false
    @State private var busy = false
    @State private var error: String?
    @State private var loaded = false

    private var company: String { application.text("company_name_snapshot").nonEmptyValue ?? application.text("company_name") }
    private var jobTitle: String { application.text("job_title_snapshot").nonEmptyValue ?? application.text("job_title") }
    private var resume: JSONValue? { resumes?.first { $0.text("id") == resumeID } }
    private var resumeTitle: String? {
        resume?.text("title").nonEmptyValue ?? (resumeID == application.text("resume_id").nonEmptyValue ? application.text("resume_title_snapshot").nonEmptyValue : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 33).padding(.top, 29)
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    field("投递日期") { dateField }
                    field("渠道") { channelField }
                }
                field("投递简历", hint: "会出现在关联资料") { resumeField }
                notesField
                if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red) }
            }
            .padding(.horizontal, 33).padding(.top, 51).padding(.bottom, 28)
            Rectangle().fill(V3.cl).frame(height: 1)
            HStack(spacing: 12) {
                Spacer()
                Button("取消", action: close).buttonStyle(DeliveryButtonStyle(primary: false)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在保存…" : "保存") { Task { await save() } }.buttonStyle(DeliveryButtonStyle(primary: true)).disabled(busy).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32).frame(height: 79)
        }
        .frame(width: 600).foregroundStyle(V3.txt)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "briefcase").font(.system(size: 17)).foregroundStyle(PD.blue)
                .frame(width: 44, height: 44).background(Color(hex: 0xEEF3FD), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("补充投递信息").font(V3.serif(22)).frame(height: 32)
                HStack(spacing: 8) {
                    Text([company, jobTitle].filter { !$0.isEmpty }.joined(separator: " · ")).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(1)
                    if !stageLabel.isEmpty {
                        Text(stageLabel).font(V3.sans(11.5, weight: .medium)).foregroundStyle(PD.blueText)
                            .padding(.horizontal, 8).frame(height: 18).background(Color(hex: 0xEEF3FD), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 23, height: 23).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("关闭").disabled(busy)
        }
    }

    private func field<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(label).font(V3.sans(13, weight: .medium))
                if let hint { Text(hint).font(V3.sans(12)).foregroundStyle(V3.fnt) }
            }.frame(height: 15)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func box<Content: View>(height: CGFloat = 39, @ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(V3.cl))
    }

    private var dateField: some View {
        Button { dateOpen = true } label: {
            box {
                HStack(spacing: 12) {
                    Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(V3.fnt)
                    Text(appliedAt.map(Self.dateText) ?? "选择投递时间").font(V3.sans(14)).foregroundStyle(appliedAt == nil ? V3.fnt : V3.txt)
                }.padding(.horizontal, 16)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy).accessibilityLabel("投递日期：\(appliedAt.map(Self.dateText) ?? "未填写")")
        .popover(isPresented: $dateOpen, arrowEdge: .bottom) {
            CareerAdvanceDateRow(label: "投递", value: $appliedAt, time: true, placeholder: "选择投递时间").padding(16)
        }
    }

    private var channelField: some View {
        Menu {
            Button("未填写") { channel = "" }
            ForEach(Array(Set([channel].filter { !$0.isEmpty } + Self.channels)).sorted { (Self.channels.firstIndex(of: $0) ?? -1) < (Self.channels.firstIndex(of: $1) ?? -1) }, id: \.self) { item in
                Button(item + (item == channel ? " ✓" : "")) { channel = item }
            }
        } label: {
            box {
                HStack {
                    Text(channel.nonEmptyValue ?? "未填写").font(V3.sans(14)).foregroundStyle(channel.isEmpty ? V3.fnt : V3.txt)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(V3.txt)
                }.padding(.leading, 15).padding(.trailing, 14)
            }.contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(busy).accessibilityLabel("投递渠道")
    }

    @ViewBuilder private var resumeField: some View {
        if picking {
            Menu {
                ForEach(resumes ?? [], id: \.self) { item in
                    Button(item.text("title")) { resumeID = item.text("id"); picking = false }
                }
            } label: {
                box {
                    HStack {
                        Text(resumeTitle ?? "选择投递简历").font(V3.sans(14)).foregroundStyle(resumeTitle == nil ? V3.fnt : V3.txt)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }.padding(.horizontal, 15)
                }.contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("选择投递简历")
        } else {
            box(height: 59) {
                HStack(spacing: 12) {
                    Text("PDF").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(V3.fnt)
                        .frame(width: 31, height: 37).background(.white, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(V3.cl))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(resumeTitle ?? "还没有关联简历").font(V3.sans(14, weight: .medium)).lineLimit(1)
                        if let resume, let updated = CareerApplication.date(resume.text("updated_at")) {
                            Text("我的简历 · \(Self.monthDay(updated)) 更新").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(resumeTitle == nil ? "选择" : "更换") { picking = true }.buttonStyle(.plain)
                        .font(V3.sans(13)).foregroundStyle(V3.link).disabled(resumes == nil || busy)
                }.padding(.leading, 13).padding(.trailing, 14)
            }
        }
    }

    @ViewBuilder private var notesField: some View {
        if showNotes {
            CareerTextArea(title: "投递备注", text: $notes, placeholder: "比如内推人、投递时的说明", minHeight: 72)
        } else {
            HStack(spacing: 8) {
                Text("补充").font(V3.sans(12)).foregroundStyle(V3.fnt)
                Button { showNotes = true } label: {
                    Text("+ 投递备注").font(V3.sans(12.5)).foregroundStyle(V3.sub).padding(.horizontal, 12).frame(height: 28)
                        .overlay(Capsule().strokeBorder(V3.cl, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Capsule())
                }.buttonStyle(.plain).disabled(busy)
            }
        }
    }

    // MARK: 数据

    private func load() async {
        guard !loaded else { return }
        loaded = true
        appliedAt = CareerApplication.date(application.text("applied_at"))
        channel = application.text("applied_channel")
        resumeID = application.text("resume_id").nonEmptyValue
        notes = application.text("notes")
        showNotes = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resumes = (try? await api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil))?["resumes"]?.items ?? []
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        let trimmedChannel = channel.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: JSONValue] = [
            "applied_channel": trimmedChannel.isEmpty ? .null : .string(trimmedChannel),
            "notes": trimmedNotes.isEmpty ? .null : .string(trimmedNotes),
            "base_lock_version": .number(Double(application["lock_version"]?.integer ?? 1)),
        ]
        if let appliedAt { body["applied_at"] = .string(ISO8601DateFormatter().string(from: appliedAt)) }
        if resumeID != application.text("resume_id").nonEmptyValue { body["resume_id"] = resumeID.map(JSONValue.string) ?? .null }
        do {
            _ = try await api.careerRequest(path: "/api/job-applications/\(application.text("id"))", method: "PUT", query: [:], body: .object(body))
            saved()
        } catch {
            self.error = CareerErrors.message(error)
        }
    }

    /// 「09-28 周一 14:20」。
    static func dateText(_ date: Date) -> String {
        let formatter = Beijing.formatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "MM-dd EEE HH:mm"
        return formatter.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let formatter = Beijing.formatter(); formatter.dateFormat = "MM.dd"
        return formatter.string(from: date)
    }
}

/// 稿 09.09 底部按钮：40 高胶囊，取消白底细边、保存墨黑。
private struct DeliveryButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13.5, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 22).frame(height: 40)
            .foregroundStyle(primary ? .white : PD.ink)
            .background(primary ? (configuration.isPressed ? Color(hex: 0x2F2F2C) : PD.ink) : (configuration.isPressed ? Color(hex: 0xF4F4F2) : .white), in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? PD.ink : V3.cl))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}
