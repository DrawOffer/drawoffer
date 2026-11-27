import DrawOfferCore
import SwiftUI

/// 记录投递（Web `progress/RecordAppliedDialog.tsx`，Figma 04 · 08.10）：待投递只走这一步，沿用推进弹窗的骨架。
/// 投递日期、渠道、简历和「现在到哪一步」是一排属性胶囊；已经收到通知的可以直接选到测评 / 笔试或面试，
/// 投递和进入那一步是同一次保存。有简历时必须选一份，一份都没有时仍可先记下投递。
struct CareerRecordAppliedSheet: View {
    let application: JSONValue
    let api: any APIClient
    /// 看板拖到某一列时的目标阶段和名称，换算成「现在到哪一步」的预选。
    let initialStage: String
    let initialLabel: String
    let close: () -> Void
    let completed: (String?) -> Void

    @State private var appliedOn: Date?
    @State private var channel = ""
    @State private var resumeID = ""
    /// nil 为还没读到列表（读失败时保存前再读一次）。
    @State private var resumes: [JSONValue]?
    @State private var step: CareerRecordApplied.Step = .screening
    @State private var interviewLabel = "一面"
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    @State private var stageID = UUID().uuidString.lowercased()
    @State private var saved: JSONValue?
    @State private var prepared = false

    private var appID: String { application.text("id") }
    private var job: String { application.text("company_name_snapshot") + " · " + application.text("job_title_snapshot") }
    private var target: String? { CareerRecordApplied.target(step, interviewLabel: interviewLabel) }
    private var resumeTitle: String? {
        resumes?.first { $0.text("id") == resumeID }?.text("title").nonEmptyValue
            ?? (!resumeID.isEmpty && resumeID == application.text("resume_id") ? application.text("resume_title_snapshot").nonEmptyValue : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            crumbs.padding(.horizontal, 25).padding(.top, 19)
            VStack(alignment: .leading, spacing: 6) {
                Text(target ?? "投递").font(V3.serif(24)).foregroundStyle(V3.txt).frame(height: 34)
                TextField("", text: $note, prompt: Text("添加备注，比如内推人、投递时的说明…").foregroundStyle(CareerAdvanceStyle.placeholder), axis: .vertical)
                    .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1...4).accessibilityLabel("备注")
            }.padding(.horizontal, 25).padding(.top, 20)
            FlowLayout(spacing: 9) { props }.padding(.horizontal, 25).padding(.top, 20)
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.horizontal, 25).padding(.top, 12) }
            Rectangle().fill(CareerAdvanceStyle.divider).frame(height: 1).padding(.top, 20)
            HStack(spacing: 10) {
                Text(CareerRecordApplied.footHint(target)).font(V3.sans(12)).foregroundStyle(CareerAdvanceStyle.hint).lineLimit(1)
                Spacer(minLength: 0)
                Button("取消", action: close).buttonStyle(CareerAdvanceButtonStyle()).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在保存…" : CareerRecordApplied.submitLabel(target)) { Task { await save() } }
                    .buttonStyle(CareerAdvanceButtonStyle(kind: .dark)).disabled(busy).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 25).padding(.vertical, 15)
        }
        .frame(width: 640, alignment: .leading)
        .interactiveDismissDisabled(busy)
        .onAppear(perform: prepare)
        .task {
            // 投递时用的简历会出现在这条记录的关联资料里
            if let list = try? await api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)["resumes"]?.items { resumes = list }
        }
    }

    private var crumbs: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(String(application.text("company_name_snapshot").prefix(1)).nonEmptyValue ?? "企").font(V3.sans(9.5, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(V3.txt, in: RoundedRectangle(cornerRadius: 4))
                Text(job).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(1).truncationMode(.tail)
                Text("待投递").font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: 320, alignment: .leading)
            .background(CareerAdvanceStyle.crumb, in: RoundedRectangle(cornerRadius: 6)).help(job)
            Text("›").font(V3.sans(14)).foregroundStyle(CareerAdvanceStyle.placeholder)
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11))
                Text(target.map { "投递 → \($0)" } ?? "记录投递").font(V3.sans(12.5, weight: .medium))
            }
            .foregroundStyle(CareerAdvanceStyle.blueText).padding(.horizontal, 10).frame(height: 28)
            .background(CareerAdvanceStyle.blueSoft, in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var props: some View {
        CareerAdvanceProp(icon: "calendar", width: 132, value: appliedOn.map { CareerAdvanceFormat.dateText($0, time: false) }, placeholder: "选择日期") {
            CareerAdvanceDateRow(label: "投递日期", value: $appliedOn, time: false)
        }
        Menu {
            Button("不填写") { channel = "" }
            ForEach(Array(NSOrderedSet(array: [channel].filter { !$0.isEmpty } + CareerRecordApplied.channels)).compactMap { $0 as? String }, id: \.self) { item in
                Button { channel = item } label: { if item == channel { Label(item, systemImage: "checkmark") } else { Text(item) } }
            }
        } label: {
            CareerAdvancePropLabel(icon: "paperplane", text: channel.nonEmptyValue ?? "投递渠道", empty: channel.isEmpty, width: 120, chevron: true)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy).accessibilityLabel("渠道")
        Menu {
            ForEach(resumes ?? [], id: \.self) { item in
                Button { resumeID = item.text("id"); error = nil } label: {
                    if item.text("id") == resumeID { Label(item.text("title"), systemImage: "checkmark") } else { Text(item.text("title")) }
                }
            }
        } label: {
            // 有简历可选时不画成虚线「选填」，没选上保存时再提示
            CareerAdvancePropLabel(icon: "doc", text: resumeTitle ?? "投递简历", empty: resumeID.isEmpty && (resumes ?? []).isEmpty, width: 152, chevron: true)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy || resumes == nil).accessibilityLabel("投递简历")
        Menu {
            ForEach(CareerRecordApplied.steps, id: \.1) { item in
                Button { step = item.0 } label: { if item.0 == step { Label(item.1, systemImage: "checkmark") } else { Text(item.1) } }
            }
        } label: {
            CareerAdvancePropLabel(icon: "", text: CareerRecordApplied.steps.first { $0.0 == step }?.1 ?? "筛选中", empty: false, width: 160, chevron: true, lead: "当前进度")
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy || saved != nil).accessibilityLabel("现在到哪一步")
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let preset = CareerRecordApplied.preset(stage: initialStage, label: initialLabel)
        step = preset.step; interviewLabel = preset.interviewLabel
        appliedOn = CareerApplication.date(application.text("created_at")) ?? Date()
        channel = application.text("applied_channel")
        resumeID = application.text("resume_id")
    }

    private func save() async {
        guard !busy else { return }
        error = nil; busy = true; defer { busy = false }
        do {
            if resumeID.isEmpty {
                let list: [JSONValue]
                if let resumes { list = resumes } else { list = try await api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)["resumes"]?.items ?? [] }
                resumes = list
                if CareerRecordApplied.resumeMissing(selected: resumeID, resumeCount: list.count) { error = "请先填写投递简历"; return }
            }
            var stage = saved
            if stage == nil {
                var body = CareerRecordApplied.stageBody(step: step, interviewLabel: interviewLabel, roundNo: CareerAdvanceSheet.inferRound(interviewLabel),
                                                         appliedOn: appliedOn, channel: channel, resumeID: resumeID)
                body["client_request_id"] = .string(stageID)
                body["base_lock_version"] = .number(Double(application["lock_version"]?.integer ?? 0))
                let result = try await api.careerRequest(path: "/api/job-applications/\(appID)/stages", method: "POST", query: [:], body: .object(body))
                stage = result["application"] ?? .null
                saved = stage
            }
            if let line = note.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue {
                do {
                    let notes = [application.text("notes").trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue, line].compactMap { $0 }.joined(separator: "\n")
                    _ = try await api.careerRequest(path: "/api/job-applications/\(appID)", method: "PUT", query: [:],
                                                    body: .object(["notes": .string(notes), "base_lock_version": .number(Double(stage?["lock_version"]?.integer ?? 0))]))
                } catch {
                    completed("投递已记录，但备注保存失败，可在详情页补充。"); return
                }
            }
            completed(nil)
        } catch {
            // 被拒的请求换一个请求号，改过再保存不会撞上旧的
            if case APIError.server(let status, _) = error, [400, 409, 422].contains(status), saved == nil { stageID = UUID().uuidString.lowercased() }
            self.error = CareerErrors.message(error)
        }
    }
}
