import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

typealias GuideModel = ResumeGuideModel

// MARK: - A2.1 你的情况

struct GuideSituationStep: View {
    @Bindable var flow: ResumeGuideFlow
    @State private var chosen: GuideModel.Stage?
    @State private var role = ""
    @State private var prefilled = false

    var body: some View {
        GuideScreen(kicker: "第 1 步，共 6 步", title: "先说说你现在的情况",
                    note: flow.filled ? "已经按求职画像填好了，在左边。从这里一步步核对，要改就改。" : "按你的情况决定先问哪些经历。") {
            Text("你现在").font(V3.sans(13)).foregroundStyle(GuideStyle.sec).padding(.top, 24).padding(.bottom, 10)
            HStack(spacing: 8) {
                ForEach(GuideModel.Stage.allCases, id: \.self) { item in
                    let on = (chosen ?? flow.stage) == item
                    Button { chosen = item } label: {
                        Text(item.label).font(V3.sans(14)).foregroundStyle(on ? V3.txt : GuideStyle.sec)
                            .padding(.horizontal, 16).frame(height: 32)
                            .background(.white, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? V3.txt : GuideStyle.control))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text("想投什么方向").font(V3.sans(13)).foregroundStyle(GuideStyle.sec).padding(.top, 24).padding(.bottom, 10)
            GuideInput(placeholder: "比如：数据分析", text: $role, maxLength: 60, submit: submit)
                .padding(.horizontal, 6).padding(.vertical, 10).guideControl()
                .accessibilityLabel("想投什么方向")
            GuideHint(text: "还没想好可以空着，先写一份通用的。")
            GuideActions(primary: flow.busy ? "正在写…" : "下一步", disabled: flow.busy,
                         link: flow.portrait != nil && !flow.filled && GuideModel.untouched(flow.guide) ? "用求职画像填好" : nil,
                         onLink: { flow.opening = true }, onPrimary: submit)
        }
        .onAppear(perform: prefill)
        .onChange(of: flow.loaded) { prefill() }
    }

    private func prefill() {
        guard !prefilled, flow.loaded else { return }
        prefilled = true
        if role.isEmpty { role = flow.profile?.text("target_role") ?? "" }
    }

    private func submit() {
        guard !flow.busy else { return }
        Task { await flow.confirmSituation(chosen ?? flow.stage, role: role.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

// MARK: - A2.2 资料

struct GuideMaterialsStep: View {
    @Environment(SessionStore.self) private var session
    @Bindable var flow: ResumeGuideFlow

    struct File: Identifiable, Equatable {
        let id: String
        let name: String
        /// uploading / reading / ready / unread / failed
        var status: String
        var datasetID: String?
        var reason: String?
    }
    @State private var files: [File] = []
    @State private var library: [JSONValue]?
    @State private var read: [String] = []
    @State private var hint: String?
    @State private var reading = false
    @State private var dropping = false
    @State private var folderID: String?
    @State private var started = false

    private var pending: Bool { files.contains { $0.status == "uploading" || $0.status == "reading" } }

    var body: some View {
        GuideScreen(kicker: "第 2 步，共 6 步", title: "有现成的资料吗？", note: "旧简历、成绩单、获奖证书、项目报告、作品都行。我先读一遍，能写的先替你写在左边。") {
            Button(action: pick) {
                VStack(spacing: 4) {
                    Text("拖进来，或点这里选文件").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                    Text("PDF、Word、图片都可以，会一起存进资料库").font(V3.sans(13)).foregroundStyle(GuideStyle.ter)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
                .background(Color.white.opacity(dropping ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(dropping ? V3.txt : Color(hex: 0xCFCFC8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 24)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                Task { await upload(await urls(providers)) }
                return true
            }
            GuideLink(title: library == nil ? "从资料库选" : "收起资料库", size: 13) { Task { await toggleLibrary() } }.padding(.top, 12)
            if let library {
                GuidePanel {
                    if library.isEmpty {
                        Text("资料库里还没有能读的文件").font(V3.sans(14)).foregroundStyle(GuideStyle.ter).padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    }
                    ForEach(Array(library.enumerated()), id: \.offset) { index, item in
                        GuideRow(title: item.text("file_name"), divider: index > 0) { add(item) }
                    }
                }.padding(.top, 12)
            }
            if !files.isEmpty {
                GuidePanel {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 12) {
                            Text(file.name).font(V3.sans(15)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(status(file)).font(V3.sans(13)).foregroundStyle(file.status == "failed" || file.status == "unread" ? V3.red : GuideStyle.ter).lineLimit(1)
                            if file.status == "unread" { GuideLink(title: "重新读", color: GuideStyle.blue, size: 13) { update(file.id) { $0.status = "ready"; $0.reason = nil } }.disabled(flow.busy) }
                            if file.status == "failed" { GuideLink(title: "重新传", color: GuideStyle.blue, size: 13) { files.removeAll { $0.id == file.id }; pick() } }
                        }
                        .padding(.horizontal, 18).frame(minHeight: 50)
                        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(GuideStyle.line).frame(height: 1) } }
                    }
                }.padding(.top, 20)
            }
            if let hint { GuideHint(text: hint) }
            if files.contains(where: { $0.status == "failed" }) { GuideHint(text: "没看清的那份不影响别的。重新传一张，或者到后面自己填也行。") }
            GuideActions(primary: reading ? "正在写…" : "下一步", disabled: flow.busy || reading, primaryDisabled: pending,
                         link: files.isEmpty ? "没有资料，直接下一步" : pending ? "不等了，先往下走" : nil,
                         onLink: moveOn, onPrimary: moveOn)
        }
        .task { await preselected() }
        .onChange(of: files) { scheduleRead() }
    }

    private func status(_ file: File) -> String {
        switch file.status {
        case "uploading": "正在上传"
        case "reading": "正在读"
        case "ready": file.datasetID.map { read.contains($0) } == true ? "读完了，写在左边" : "正在读"
        default: file.reason ?? ""
        }
    }

    private func moveOn() { Task { if read.isEmpty { await flow.skip() } else { await flow.next() } } }

    private func preselected() async {
        if flow.guide["steps"]?["materials"]?.text("status") == "written" { read = (flow.guide["dataset_ids"]?.items ?? []).compactMap(\.stringValue) }
        let ids = (flow.guide["dataset_ids"]?.items ?? []).compactMap(\.stringValue)
        guard !ids.isEmpty, files.isEmpty else { return }
        let datasets = (try? await flow.api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil))?["datasets"]?.items ?? []
        files = ids.map { id in File(id: id, name: datasets.first { $0.text("id") == id }?.text("file_name") ?? "资料库里的资料", status: "ready", datasetID: id) }
    }

    private func toggleLibrary() async {
        if library != nil { library = nil; return }
        hint = nil
        do {
            let datasets = try await flow.api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil)["datasets"]?.items ?? []
            library = Array(datasets.filter { $0.text("parse_status") == "succeeded" && !["audio", "video"].contains($0.text("asset_kind")) }.prefix(12))
        } catch { hint = "没读到资料库，再点一次试试。" }
    }

    private func add(_ item: JSONValue) {
        library = nil
        if files.filter({ $0.status != "failed" }).count >= GuideModel.maxMaterials { hint = "一次最多读 \(GuideModel.maxMaterials) 份，多的没有加进来。"; return }
        guard !files.contains(where: { $0.datasetID == item.text("id") }) else { return }
        files.append(File(id: item.text("id"), name: item.text("file_name"), status: "ready", datasetID: item.text("id")))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = GuideModel.materialExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        Task { await upload(panel.urls) }
    }

    private func urls(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
        }
        return urls
    }

    private func folder() async throws -> String {
        if let folderID { return folderID }
        let list = try await flow.api.careerRequest(path: "/api/datasets/folders", method: "GET", query: [:], body: nil)["folders"]?.items ?? []
        var id = list.first { $0.text("name") == GuideModel.folderName }?.text("id") ?? ""
        if id.isEmpty {
            id = try await flow.api.careerRequest(path: "/api/datasets/folders", method: "POST", query: [:], body: .object(["name": .string(GuideModel.folderName)])).text("id")
        }
        folderID = id
        return id
    }

    private func upload(_ list: [URL]) async {
        let taken = files.filter { $0.status != "failed" }.count
        let picked = Array(list.prefix(max(0, GuideModel.maxMaterials - taken)))
        hint = picked.count < list.count ? "一次最多读 \(GuideModel.maxMaterials) 份，多的没有加进来。" : nil
        for url in picked {
            let key = UUID().uuidString
            guard GuideModel.materialExtensions.contains(url.pathExtension.lowercased()) else {
                files.append(File(id: key, name: url.lastPathComponent, status: "failed", reason: "这种格式读不了，换成 PDF、Word 或图片")); continue
            }
            files.append(File(id: key, name: url.lastPathComponent, status: "uploading"))
            do {
                let snapshot = try DatasetUpload.snapshot(url, folder: try await folder(), limit: 50 * 1024 * 1024)
                defer { snapshot.discard() }
                let id = try await flow.api.uploadDataset(snapshot).text("id")
                update(key) { $0.status = "reading"; $0.datasetID = id }
                let ok = await parsed(id)
                update(key) { $0.status = ok ? "ready" : "failed"; $0.reason = ok ? nil : "没读出文字，可能拍得太斜或太糊" }
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                update(key) { $0.status = "failed"; $0.reason = "没传上去" }
            }
        }
    }

    private func update(_ key: String, _ change: (inout File) -> Void) {
        if let index = files.firstIndex(where: { $0.id == key }) { change(&files[index]) }
    }

    private func parsed(_ id: String) async -> Bool {
        for _ in 0..<90 {
            let datasets = (try? await flow.api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil))?["datasets"]?.items ?? []
            if let record = datasets.first(where: { $0.text("id") == id }) {
                let parse = record["parse_status"]
                if record.text("parse_status") == "succeeded" || ((parse == nil || parse == .null) && record.text("upload_status") == "succeeded") { return true }
                if record.text("parse_status") == "failed" || record.text("upload_status") == "failed" { return false }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// 都传完、有没读过的就交给 `materials:compose` 一次读完写上纸（Web 同样不等用户点）。
    private func scheduleRead() {
        let fresh = Array(Set(files.filter { $0.status == "ready" }.compactMap(\.datasetID).filter { !read.contains($0) }))
        guard !pending, !reading, !flow.busy, !fresh.isEmpty else { return }
        reading = true
        Task {
            defer { reading = false }
            if flow.guide.text("current_step") == "materials" { try? await flow.change("set_materials", datasets: Array(Set(read + fresh))) }
            var empty = false
            let ok = await flow.write {
                let result = try await flow.post("materials:compose", .object(["dataset_ids": .array(fresh.map(JSONValue.string)), "write": .bool(true)]))
                if result["resume"] == nil || result["resume"] == .null { empty = true; throw APIError.server(status: 422, code: "RESUME_GUIDE_MATERIALS_EMPTY") }
            }
            if ok { read += fresh; return }
            if empty { flow.notice = "读到了文字，但里面没有简历能用的内容（学校、经历、技能）。换一份试试，或者直接下一步自己填。" }
            for index in files.indices where files[index].datasetID.map(fresh.contains) == true {
                files[index].status = "unread"; files[index].reason = empty ? "没有能写进简历的内容" : "没读成"
            }
        }
    }
}

// MARK: - A2.22 基本信息

struct GuideBasicsStep: View {
    @Bindable var flow: ResumeGuideFlow
    @State private var info = GuideModel.BasicInfo()
    @State private var educations: [GuideModel.EducationForm] = []
    @State private var removed: [String] = []
    @State private var ready = false
    @State private var prefilled = false
    @State private var missing: Int?
    @State private var dropped: (education: GuideModel.EducationForm, index: Int)?

    var body: some View {
        GuideScreen(kicker: "第 3 步，共 6 步", title: prefilled ? "这些对吗？" : "你的基本信息", note: note) {
            if ready {
                GuidePanel {
                    GuideField(label: "姓名", divider: false) { GuideInput(placeholder: "你的名字", text: save($info.name), maxLength: 60) }
                    GuideField(label: "手机") { GuideInput(placeholder: "手机号", text: save($info.phone), maxLength: 40) }
                    GuideField(label: "邮箱") { GuideInput(placeholder: "补一个邮箱，HR 常用它联系", text: save($info.email), maxLength: 120) }
                }.padding(.top, 20)
                ForEach(educations.indices, id: \.self) { index in
                    GuideGroupHead(title: GuideModel.educationLabel(index)) {
                        if educations.count > 1 { GuideLink(title: "删掉", size: 12.5) { drop(index) }.disabled(flow.busy) }
                    }
                    GuidePanel {
                        GuideField(label: "学校", divider: false) { GuideInput(placeholder: "比如：某某大学", text: edu(index, \.school), maxLength: 100) }
                        GuideField(label: "专业学历") {
                            HStack(spacing: 8) {
                                GuideInput(placeholder: "专业", text: edu(index, \.major), maxLength: 100)
                                    .frame(width: max(44, min(200, CGFloat(max(educations[index].major.count, 2)) * 16 + 6)))
                                Text("·").font(V3.sans(15)).foregroundStyle(GuideStyle.ter)
                                Menu {
                                    Button("不填") { edu(index, \.degree).wrappedValue = "" }
                                    ForEach(GuideModel.degrees, id: \.self) { degree in Button(degree) { edu(index, \.degree).wrappedValue = degree } }
                                } label: {
                                    Text(educations[index].degree.isEmpty ? "学历" : educations[index].degree).font(V3.sans(15))
                                        .foregroundStyle(educations[index].degree.isEmpty ? Color(hex: 0xA8A8A1) : V3.txt)
                                }.menuStyle(.button).buttonStyle(.plain).fixedSize().accessibilityLabel("学历")
                                Spacer(minLength: 0)
                            }
                        }
                        GuideField(label: "时间") {
                            HStack(spacing: 6) {
                                GuideInput(placeholder: "年.月", text: edu(index, \.start), maxLength: 20).frame(width: 84)
                                Text("–").foregroundStyle(GuideStyle.ter)
                                GuideInput(placeholder: "年.月", text: edu(index, \.end), maxLength: 20).frame(width: 84)
                            }
                        }
                        GuideField(label: "GPA") { GuideInput(placeholder: "没有可以空着", text: edu(index, \.gpa), maxLength: 40) }
                    }
                    if missing == index { GuideHint(text: "这一段还没写学校。", color: V3.red) }
                }
                if let dropped {
                    HStack(spacing: 8) {
                        Text("“\(dropped.education.school.trimmingCharacters(in: .whitespaces).isEmpty ? GuideModel.educationLabel(dropped.index) : dropped.education.school)”删掉了。")
                            .font(V3.sans(13)).foregroundStyle(GuideStyle.sec)
                        GuideLink(title: "放回来", color: GuideStyle.blue, size: 13, action: putBack)
                    }.padding(.top, 12)
                }
                GuideActions(primary: flow.busy ? "正在写…" : prefilled ? "对，下一步" : "下一步", disabled: flow.busy,
                             link: educations.count < GuideModel.maxEducations ? "+ 再加一段教育" : nil, onLink: add, onPrimary: submit)
            }
        }
        .onAppear(perform: start)
        .onChange(of: flow.loaded) { start() }
    }

    private var note: String {
        let written = !GuideModel.basicInfo(flow.document(), samples: flow.samples).name.isEmpty || educations.contains { $0.entryID != nil }
        guard prefilled else { return "写在简历最上面，HR 靠这些联系你。" }
        return written ? "左边已经写上了。不对的直接改，空着的补一下。" : "从你的求职画像里带出来的，核对一下，下一步写到左边。"
    }

    private func start() {
        guard !ready, flow.loaded else { return }
        if let draft = flow.basicsDraft {
            info = draft.info; educations = draft.educations; removed = draft.removed
        } else {
            info = GuideModel.basicInfo(flow.document(), samples: flow.samples)
            educations = GuideModel.educations(flow.document(), profile: flow.profile, samples: flow.samples)
        }
        prefilled = !info.name.isEmpty || !(educations.first?.school.isEmpty ?? true)
        ready = true
    }

    private func keep() { flow.basicsDraft = (info, educations, removed) }

    private func save(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; keep() })
    }

    private func edu(_ index: Int, _ key: WritableKeyPath<GuideModel.EducationForm, String>) -> Binding<String> {
        Binding(get: { educations.indices.contains(index) ? educations[index][keyPath: key] : "" },
                set: { value in
                    guard educations.indices.contains(index) else { return }
                    educations[index][keyPath: key] = value; missing = nil; keep()
                })
    }

    private func add() { dropped = nil; educations.append(GuideModel.EducationForm()); keep() }

    private func drop(_ index: Int) {
        let education = educations[index]
        missing = nil
        dropped = education.entryID != nil || !education.school.isEmpty || !education.major.isEmpty ? (education, index) : nil
        educations.remove(at: index)
        if let id = education.entryID { removed.append(id) }
        keep()
    }

    private func putBack() {
        guard let dropped else { return }
        educations.insert(dropped.education, at: min(dropped.index, educations.count))
        removed.removeAll { $0 == dropped.education.entryID }
        self.dropped = nil
        keep()
    }

    private func submit() {
        if let at = GuideModel.educationMissingSchool(educations) { missing = at; return }
        dropped = nil
        Task {
            if let written = await flow.saveBasics(info, educations: educations, removed: removed) {
                educations = written.isEmpty ? [GuideModel.EducationForm()] : written; removed = []
            }
        }
    }
}

// MARK: - A2.8 技能

struct GuideSkillsStep: View {
    @Bindable var flow: ResumeGuideFlow
    @State private var names: [String]?
    @State private var written: [String]?
    @State private var terms: [String] = []
    @State private var adding = false
    @State private var draft = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        GuideScreen(kicker: "第 5 步 · 技能与优势", title: "你会哪些？",
                    note: written != nil ? "左边已经写了这些。不动就照原样留着；增减之后，这一栏会重新写，一项一条。"
                        : "从你写的经历里找出来的。不会的点 × 去掉，漏了的加上；左边一项写一条、展开写具体，不用自己评熟练程度。") {
            if let names {
                VStack(alignment: .leading, spacing: 12) {
                    Text(written != nil ? "左边已经写的" : names.isEmpty ? "经历里没找到技能，自己加几个" : "经历里用到的").font(V3.sans(13)).foregroundStyle(GuideStyle.sec)
                    GuideChips {
                        ForEach(names, id: \.self) { name in
                            HStack(spacing: 6) {
                                Text(name).font(V3.sans(14)).foregroundStyle(V3.txt)
                                Button { self.names = names.filter { $0 != name } } label: { Text("×").foregroundStyle(GuideStyle.ter) }
                                    .buttonStyle(.plain).accessibilityLabel("去掉 \(name)")
                            }.padding(.horizontal, 12).frame(height: 30).background(V3.field, in: Capsule())
                        }
                        if adding {
                            TextField("技能名，回车加上", text: $draft).textFieldStyle(.plain).font(V3.sans(14)).frame(width: 140).focused($focused)
                                .padding(.horizontal, 12).frame(height: 30).overlay(Capsule().strokeBorder(GuideStyle.control))
                                .onSubmit { add(draft); draft = "" }
                                .onAppear { focused = true }
                                .onChange(of: focused) { if !focused { add(draft); draft = ""; adding = false } }
                        } else {
                            Button { adding = true } label: {
                                Text("+ 加一个").font(V3.sans(14)).foregroundStyle(GuideStyle.sec).padding(.horizontal, 12).frame(height: 30)
                                    .overlay(Capsule().strokeBorder(GuideStyle.control, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))).contentShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    let saved = suggestions(names)
                    if !saved.isEmpty {
                        Rectangle().fill(GuideStyle.line).frame(height: 1).padding(.vertical, 4)
                        Text(terms.isEmpty ? "你在求职资料里记过这些，会的点一下" : "经历里用到、或求职资料里记过的，会的点一下").font(V3.sans(13)).foregroundStyle(GuideStyle.sec)
                        GuideChips {
                            ForEach(saved, id: \.self) { name in
                                Button { add(name) } label: {
                                    Text("+ \(name)").font(V3.sans(14)).foregroundStyle(GuideStyle.sec).padding(.horizontal, 12).frame(height: 30)
                                        .overlay(Capsule().strokeBorder(GuideStyle.control)).contentShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 14)).padding(.top, 20)
                GuideActions(primary: flow.busy ? "正在写…" : names.isEmpty ? "先不写技能，下一步" : "下一步", disabled: flow.busy,
                             link: failed ? "先不写，下一步" : nil, onLink: { Task { await flow.skip() } }) { save(names) }
            }
        }
        .onAppear(perform: start)
    }

    private func start() {
        guard names == nil else { return }
        let document = flow.document()
        let sample = (document["sections"]?.items ?? []).contains { $0.text("semantic_kind") == "skills" && flow.samples.contains($0.text("node_id")) }
        let onPaper = sample ? [] : Array(GuideModel.uniqueNames(GuideModel.skillsOnPaper(document).map(\.name)).prefix(30))
        let used = GuideModel.techTermsOnPaper(document, samples: flow.samples)
        if !onPaper.isEmpty { written = onPaper; terms = used }
        names = onPaper.isEmpty ? Array(GuideModel.uniqueNames(used).prefix(16)) : onPaper
    }

    private func suggestions(_ names: [String]) -> [String] {
        let list = (flow.profile?["skills"]?.items ?? []).compactMap { $0.stringValue ?? $0["name"]?.stringValue }
        let have = Set(names.map { $0.lowercased().replacingOccurrences(of: " ", with: "") })
        return Array(GuideModel.uniqueNames(terms + list).filter { $0.count <= 30 && !have.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) }.prefix(10))
    }

    private func add(_ text: String) { names = GuideModel.addingSkills(names ?? [], text) }

    /// 和纸上已写的不一样才重写（`skills:compose`）；全去掉了把纸上这一栏也拿掉。
    private func save(_ names: [String]) {
        let changed = written == nil || names != written
        Task {
            let ok = await flow.write {
                if names.isEmpty && changed {
                    let own = (flow.document()["sections"]?.items ?? []).filter { $0.text("semantic_kind") == "skills" && !flow.samples.contains($0.text("node_id")) }
                        .map { JSONValue.string($0.text("node_id")) }
                    if !own.isEmpty { try await flow.writeOperations([.object(["op": .string("remove"), "node_ids": .array(own)])]) }
                }
                if !names.isEmpty && changed {
                    try await flow.post("skills:compose", .object(["skills": .array(names.map { .object(["name": .string($0)]) })]))
                }
                try await flow.change(names.isEmpty ? "skip_step" : "next")
            }
            failed = !ok
            if ok { flow.finishing = false }
        }
    }
}

/// 一排会折行的胶囊。
struct GuideChips<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { GuideFlowLayout(spacing: 8) { content() } }
}

struct GuideFlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

// MARK: - A2.9 个人优势

struct GuideStrengthStep: View {
    @Bindable var flow: ResumeGuideFlow
    @State private var text: String?
    @State private var kept: String?
    @State private var ask = ""
    @State private var failed = false
    @State private var started = false
    @State private var before: JSONValue?

    private var title: String { GuideModel.sectionTitle([flow.templateSample], kind: "profile") ?? "个人优势" }
    private var templateHad: Bool { (flow.templateSample?["sections"]?.items ?? []).contains { $0.text("semantic_kind") == "profile" } }

    var body: some View {
        if failed {
            GuideScreen(kicker: "第 5 步 · 技能与优势", title: "你的个人优势", note: flow.busy ? "正在按你前面写的经历写一段…" : "可以再写一次，也可以先不写，之后在编辑器里补。") {
                GuideActions(primary: flow.busy ? "正在写…" : "再写一次", disabled: flow.busy, link: "先不写，下一步", onLink: done) {
                    Task { failed = !(await compose(nil, nil)) }
                }
            }
        } else {
            GuideScreen(kicker: "第 5 步 · 技能与优势", title: "你的个人优势", note: note) {
                GuideNote(text: "想换个说法，或者觉得自己还有别的长处（比如沟通、细心、学得快），直接说。").padding(.top, 12)
                GuidePanel {
                    GuideField(label: "", divider: false) { GuideInput(placeholder: "比如“加一句我做事细心，报表很少出错”", text: $ask, maxLength: 300, submit: revise) }
                        .padding(.leading, -88)
                }.padding(.top, 20).disabled(flow.busy || text == nil)
                GuideActions(primary: flow.busy ? "正在写…" : ask.isEmpty ? "就这样，下一步" : "按这个改", disabled: flow.busy || text == nil,
                             link: kept != nil ? (text?.isEmpty == false ? "放回原来写的" : nil) : before != nil ? "不要这一栏" : nil,
                             onLink: undo) { if ask.trimmingCharacters(in: .whitespaces).isEmpty { done() } else { revise() } }
            }
            .onAppear(perform: start)
        }
    }

    private var note: String {
        guard let text else { return "正在按你前面写的经历写一段…" }
        if kept != nil { return text.isEmpty ? "左边“\(title)”一栏已经有内容，可以就这样留着。" : "按你说的改好了，在左边“\(title)”一栏。" }
        return templateHad ? "按你前面说的经历写了一段，在左边“\(title)”一栏。"
            : "按你前面说的经历写了一段，在左边“\(title)”一栏。原来的简历里没有这一栏，已经替你加上，之后换模板也会带着。"
    }

    private func start() {
        guard !started else { return }
        started = true
        before = flow.document()
        if let own = GuideModel.ownProfileText(flow.document(), samples: flow.samples) { kept = own; text = ""; return }
        Task { failed = !(await compose(nil, nil)) }
    }

    private func compose(_ instruction: String?, _ previous: String?) async -> Bool {
        await flow.write {
            let result = try await flow.post("profile:compose", .object(["instruction": instruction.map(JSONValue.string) ?? .null,
                                                                         "previous": previous.map(JSONValue.string) ?? .null, "title": .string(title)]))
            text = result.text("text")
        }
    }

    private func revise() {
        let said = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !flow.busy, let text else { return }
        Task { if await compose(said, text.isEmpty ? kept : text) { ask = "" } }
    }

    /// 不要这一栏 / 放回原来写的：纸面回到进这一步之前，按普通编辑保存。
    private func undo() {
        guard let before else { return }
        flow.restore(before)
        if kept != nil { text = "" } else { done() }
    }

    private func done() { flow.notice = nil; flow.seenFinish = true; flow.finishing = true }
}

// MARK: - A2.10 成稿

struct GuideFinishStep: View {
    @Environment(SessionStore.self) private var session
    @Bindable var flow: ResumeGuideFlow
    @State private var templates: [ResumeTemplate]?

    var body: some View {
        GuideScreen(kicker: "第 6 步，共 6 步", title: "挑一个样子", note: "点一下，左边就换成这个样子。进去以后还能换模板、改每一句。") {
            if let templates, !templates.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(templates) { template in
                        let on = template.id == flow.templateID
                        Button { choose(template) } label: {
                            VStack(spacing: 8) {
                                TemplateThumbnail(template: template, radius: 6, bordered: false)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? V3.txt : GuideStyle.line, lineWidth: on ? 1.5 : 1))
                                Text(template.name).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : GuideStyle.sec).lineLimit(1)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(flow.busy).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.padding(.top, 24)
            }
            GuideActions(primary: flow.busy ? "正在整理…" : "打开简历", disabled: flow.busy) { Task { await flow.finish() } }
        }
        .task { await load() }
    }

    private func load() async {
        guard templates == nil else { return }
        let items = ((try? await session.api.listResumeTemplates()) ?? []).filter { !ResumeRequest.retiredTemplateKeys.contains($0.key) }
        let current = flow.templateID.flatMap { id in items.first { $0.id == id } }
        templates = Array(((current.map { [$0] } ?? []) + items.filter { $0.id != flow.templateID }).prefix(3))
    }

    private func choose(_ template: ResumeTemplate) {
        guard template.id != flow.templateID else { return }
        Task {
            flow.busy = true; flow.notice = nil
            if await flow.applyTemplate(template) != nil { flow.notice = "没换上，请重试。" } else { flow.templateID = template.id }
            flow.busy = false
        }
    }
}

// MARK: - A2.3 经历

struct GuideExperienceStep: View {
    @Bindable var flow: ResumeGuideFlow
    @State private var empty = false
    /// 说完了还有写到一半的段：先带回去看一眼，只问一次
    @State private var pending: String?
    @State private var asked = false
    @State private var link = ""
    @State private var linked = false

    private var list: [GuideModel.Category] { GuideModel.categories(stage: flow.stage, sample: flow.templateSample) }
    private var index: Int { max(0, list.firstIndex { $0.key == flow.category } ?? 0) }
    private var category: GuideModel.Category { list[index] }
    private var ownLink: String { GuideModel.basicInfo(flow.document(), samples: flow.samples).link }

    var body: some View {
        if empty {
            GuideScreen(kicker: "第 4 步 · 经历", title: "一段经历都还没有？", note: "很正常，大一大二的同学大多这样。下面这些也能写成一段，点一个说说看：") {
                GuidePanel {
                    GuideRow(title: "课上做过的大作业、实验或课程报告", side: "算项目 ›", divider: false) { empty = false; flow.category = "project" }
                    GuideRow(title: "自己学的东西，比如自学 Python、考过的证", side: "算技能 ›") { empty = false; Task { await flow.next() } }
                    GuideRow(title: "帮过忙的事，比如组织班级活动、做家教", side: "算校园或兼职 ›") { empty = false; flow.category = "campus" }
                }.padding(.top, 20)
                GuideActions(primary: "先跳过，去写技能", disabled: flow.busy) { Task { await flow.next() } }
            }
        } else if category.key == "portfolio" {
            let changed = !link.trimmed.isEmpty && link.trimmed != ownLink
            GuideScreen(kicker: "第 4 步 · 经历", title: category.question, note: category.note, tabs: { tabs }) {
                GuidePanel {
                    GuideField(label: "", divider: false) { GuideInput(placeholder: "贴一个作品链接", text: $link, maxLength: 300) }.padding(.leading, -88)
                }.padding(.top, 20)
                GuideActions(primary: flow.busy ? "正在写…" : changed ? "写上去，经历说完了" : ownLink.isEmpty ? "没有，经历都说完了" : "就这样，下一步",
                             disabled: flow.busy) {
                    guard changed else { moveOn(); return }
                    Task { if await writePortfolio(link.trimmed) { moveOn() } }
                }
            }
            .onAppear { if !linked { linked = true; link = ownLink } }
        } else {
            GuideScreen(kicker: "第 4 步 · 经历", title: category.question, note: category.note, tabs: { tabs }) {
                GuideCategoryEntries(flow: flow, category: category, list: list, pending: pending == category.key, moveOn: moveOn).id(category.key)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 14) {
            ForEach(Array(list.enumerated()), id: \.element.key) { position, item in
                Button { flow.notice = nil; pending = nil; flow.category = item.key } label: {
                    Text(item.label).font(V3.sans(13.5, weight: position == index ? .semibold : .regular))
                        .foregroundStyle(position == index ? V3.txt : GuideStyle.ter).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(flow.busy).accessibilityAddTraits(position == index ? .isSelected : [])
            }
        }.padding(.top, 12).accessibilityLabel("经历类别")
    }

    private func moveOn() {
        flow.notice = nil
        // 回来看过没写完的那段了，不再把后面的类走一遍
        if pending == nil, index < list.count - 1 { flow.category = list[index + 1].key; return }
        pending = nil
        let drafts = flow.segmentDrafts.keys.map { String($0.split(separator: ":").first ?? "") }
        if let left = list.first(where: { drafts.contains($0.key) }), !asked {
            asked = true; pending = left.key; flow.category = left.key; return
        }
        let any = list.contains { $0.key != "portfolio" && !GuideModel.categoryEntries(flow.document(), $0, all: list, samples: flow.samples).isEmpty }
        if any { flow.category = nil; Task { await flow.next() } } else { empty = true }
    }

    /// 作品链接写在基本信息的联系方式里：临时走回基本信息写上，再回到经历；界面不跟着跳。
    private func writePortfolio(_ value: String) async -> Bool {
        var info = GuideModel.basicInfo(flow.document(), samples: flow.samples)
        info.link = value
        flow.pinned = true
        defer { flow.pinned = false }
        return await flow.write {
            try await flow.reach("basics")
            do { try await flow.writeOperations(GuideModel.basicInfoOperations(info)) } catch { try? await flow.reach("experience"); throw error }
            try await flow.reach("experience")
        }
    }
}

/// 一类经历：写好的列在上面，下面是正在写的一段；写到一半的按“类别:段”留在 flow 里。
struct GuideCategoryEntries: View {
    @Bindable var flow: ResumeGuideFlow
    let category: GuideModel.Category
    let list: [GuideModel.Category]
    let pending: Bool
    let moveOn: () -> Void
    @State private var segment: GuideModel.Segment?
    @State private var started = false
    @State private var justWrote: String?
    @State private var deleted: (entryID: String, name: String, before: JSONValue, draft: GuideModel.Segment?)?
    @State private var round = 0

    private var entries: [JSONValue] { GuideModel.categoryEntries(flow.document(), category, all: list, samples: flow.samples) }
    private func key(_ id: String?) -> String { "\(category.key):\(id ?? "new")" }
    private var dirty: Bool { segment.map { flow.segmentDrafts[key($0.entryID)] != nil } ?? false }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 0) {
            if !entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Button { open(GuideModel.segment(category, entry: entry)) } label: {
                            HStack(spacing: 12) {
                                Text(GuideModel.entryName(entry)).font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(GuideModel.entryTime(entry)).font(V3.sans(13)).foregroundStyle(GuideStyle.ter)
                            }.padding(.vertical, 13).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(flow.busy)
                        .overlay(alignment: .bottom) { Rectangle().fill(GuideStyle.line).frame(height: 1) }
                    }
                }.padding(.top, 20)
            }
            if segment != nil, pending, dirty { GuideHint(text: "这一段还没写上去。写上去，或者先放着往下走。", color: GuideStyle.sec) }
            if let segment {
                GuideSegmentForm(flow: flow, category: category, initial: segment,
                                 order: (entries.firstIndex { $0.text("node_id") == segment.entryID } ?? entries.count) + 1,
                                 draftKey: key(segment.entryID), onWrite: save) {
                    if segment.entryID != nil { GuideLink(title: "不改了", action: drop).disabled(flow.busy) }
                    else if !entries.isEmpty || dirty { GuideLink(title: "不加了", action: drop).disabled(flow.busy) }
                    GuideLink(title: pending ? "先放着，往下走" : dirty ? "先放着，下一类" : entries.isEmpty ? "这一类没有，下一类" : "没有了，下一类", action: moveOn)
                        .disabled(flow.busy)
                    if segment.entryID != nil {
                        Spacer(minLength: 0)
                        GuideLink(title: "删掉这段", action: remove).disabled(flow.busy)
                    }
                }
                .id("\(segment.entryID ?? "new")-\(round)")
            } else if let deleted {
                HStack(spacing: 8) {
                    Text("“\(deleted.name)”删掉了。").font(V3.sans(14)).foregroundStyle(V3.txt)
                    GuideLink(title: "放回来", color: GuideStyle.blue, action: putBack).disabled(flow.busy)
                }.padding(.top, 18)
            } else if let justWrote {
                GuideHint(text: "“\(justWrote)”写在左边了。不对的地方，点上面这一段改。", color: GuideStyle.sec).padding(.top, 8)
            }
            if segment == nil {
                GuideActions(primary: pending ? "经历就这些，下一步" : entries.isEmpty ? "这一类没有，下一类" : "\(category.label)就这些，下一类",
                             disabled: flow.busy, link: "+ 再加一段\(category.label)", onLink: { open(GuideModel.Segment()) }, onPrimary: moveOn)
            }
        }
        .onAppear(perform: start)
    }

    /// 进来时有写到一半的就接着写，已经有段的先列出来，没有就直接开第 1 段。
    private func start() {
        guard !started else { return }
        started = true
        if flow.segmentDrafts[key(nil)] != nil { segment = GuideModel.Segment(); return }
        if let half = entries.first(where: { flow.segmentDrafts[key($0.text("node_id"))] != nil }) { segment = GuideModel.segment(category, entry: half); return }
        segment = entries.isEmpty ? GuideModel.Segment() : nil
    }

    private func open(_ next: GuideModel.Segment) { flow.notice = nil; segment = next; justWrote = nil; deleted = nil }

    private func close() { if let segment { flow.segmentDrafts[key(segment.entryID)] = nil }; segment = nil }

    private func drop() {
        flow.notice = nil
        if let segment { flow.segmentDrafts[key(segment.entryID)] = nil }
        if entries.isEmpty { round += 1; segment = GuideModel.Segment() } else { segment = nil }
    }

    /// 已有的一段只改了标题（名称、角色、时间）：直接写字段，不调 AI；一个字没改就收起。
    private func save(_ filled: GuideModel.Segment) {
        guard let segment else { return }
        let heading = segment.entryID != nil && filled.same(segment, keys: [\.tech, \.intro, \.did])
        if heading && filled.same(segment) { close(); return }
        let category = category
        Task {
            let ok = await flow.write {
                if heading, let id = segment.entryID {
                    guard let own = GuideModel.entryByID(flow.document(), id) else { throw APIError.server(status: 409, code: "TARGET_STALE") }
                    try await flow.writeOperations([.object(["op": .string("fill_entry"), "entry_id": .string(id),
                                                             "entry": .object(["fields": GuideModel.experienceFields(filled, kind: category.kind, own: own)])])])
                } else {
                    try await flow.post("experience:compose", GuideModel.experienceBody(category, segment: filled, document: flow.document()))
                }
            }
            if ok { close(); justWrote = filled.name.trimmed }
        }
    }

    private func remove() {
        guard let id = segment?.entryID else { return }
        let name = GuideModel.entryName(entries.first { $0.text("node_id") == id })
        let draft = flow.segmentDrafts[key(id)]
        let before = flow.document()
        Task {
            let ok = await flow.write {
                try await flow.post("writes", .object(["step": .string(flow.guide.text("current_step")),
                                                       "operations": .array([.object(["op": .string("remove"), "node_ids": .array([.string(id)])])])]))
            }
            guard ok else { return }
            close(); justWrote = nil
            deleted = (id, name, before, draft)
        }
    }

    /// 放回来：按普通编辑保存删之前的那段，改到一半的也一起回来。
    private func putBack() {
        guard let deleted else { return }
        flow.restore(GuideModel.withEntryBack(flow.document(), before: deleted.before, entryID: deleted.entryID))
        if let draft = deleted.draft { flow.segmentDrafts[key(deleted.entryID)] = draft }
        self.deleted = nil
    }
}

/// 一段经历（A2.32 / A2.33）：名称在上、框在下，短的并排；右上角“让职绘帮我填”只管这一段。
struct GuideSegmentForm<Links: View>: View {
    @Bindable var flow: ResumeGuideFlow
    let category: GuideModel.Category
    let initial: GuideModel.Segment
    let order: Int
    let draftKey: String
    let onWrite: (GuideModel.Segment) -> Void
    @ViewBuilder var links: () -> Links

    @State private var form = GuideModel.Segment()
    @State private var ready = false
    @State private var helping = false
    @State private var said = ""
    @State private var filling = false
    @State private var filled = false
    @State private var helpNote: String?
    @State private var missing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("第 \(order) 段").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                Spacer(minLength: 12)
                GuideLink(title: helping ? "收起" : "让职绘帮我填", color: GuideStyle.blue) { helping.toggle() }
            }
            if helping { help }
            HStack(alignment: .top, spacing: 10) {
                GuideFormField(label: category.name) { GuideControl(placeholder: category.nameHint, text: bind(\.name), maxLength: 100, invalid: missing == "name") }
                GuideFormField(label: "时间") {
                    HStack(spacing: 8) {
                        GuideInput(placeholder: "年.月", text: bind(\.start), maxLength: 20).font(V3.sans(14))
                        Text("–").foregroundStyle(Color(hex: 0xA8A8A1))
                        GuideInput(placeholder: "年.月", text: bind(\.end), maxLength: 20)
                    }.guideControl()
                }.frame(width: 160)
            }
            if let lines = category.lines {
                HStack(alignment: .top, spacing: 10) {
                    GuideFormField(label: form.techLabel ?? lines.tech, optional: true) { GuideControl(placeholder: "用到的技术或工具", text: bind(\.tech), maxLength: 200) }
                    role.frame(width: 160)
                }
                GuideFormField(label: form.introLabel ?? lines.intro, optional: true) {
                    GuideControl(placeholder: category.kind == "project" ? "做什么用的，你管哪一块" : "公司做什么业务，你管哪一块", text: bind(\.intro), maxLength: 400, multiline: true)
                }
            } else { role }
            GuideFormField(label: "做了什么") {
                GuidePointLines(text: bind(\.did), placeholder: "一行写一件事，大白话就行")
                    .padding(.horizontal, 11).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(missing == "did" ? V3.red : GuideStyle.control))
            }
            if let missing { GuideHint(text: missing == "name" ? "还没写\(category.name)。" : "还没写做了什么。", color: GuideStyle.sec).padding(.top, -10) }
            HStack(spacing: 18) {
                Button(action: submit) {
                    Text(flow.busy ? "正在写…" : "写上去").font(V3.sans(14, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 20).frame(height: 36).background(V3.txt.opacity(canWrite ? 1 : 0.35), in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).disabled(!canWrite)
                links()
            }.padding(.top, 8)
        }
        .padding(.top, 18)
        .onAppear {
            guard !ready else { return }
            ready = true
            if var draft = flow.segmentDrafts[draftKey] {
                draft.entryID = initial.entryID; draft.techLabel = initial.techLabel; draft.introLabel = initial.introLabel
                form = draft
            } else { form = initial }
        }
    }

    private var canWrite: Bool { !flow.busy && !filling && !(form.name.trimmed.isEmpty && form.did.trimmed.isEmpty) }

    private var role: some View {
        GuideFormField(label: category.role) { GuideControl(placeholder: category.roleHint, text: bind(\.role), maxLength: 100) }
    }

    @ViewBuilder private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            if filled {
                Text(said).font(V3.sans(14)).foregroundStyle(V3.txt).lineSpacing(4).padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xE9E9E3), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    Text("拆好填进下面了，看看对不对").font(V3.sans(13)).foregroundStyle(GuideStyle.sec)
                    Spacer()
                    GuideLink(title: "重新填", color: GuideStyle.blue, size: 13) { filled = false }
                }
            } else {
                TextEditor(text: $said).font(V3.sans(14)).scrollContentBackground(.hidden).frame(minHeight: 68)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(alignment: .topLeading) {
                        if said.isEmpty {
                            Text("用大白话说说这一段：做的什么、什么时候、你负责哪部分、结果怎么样").font(V3.sans(14)).foregroundStyle(Color(hex: 0xA8A8A1))
                                .padding(.horizontal, 17).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                    .background(Color(hex: 0xE9E9E3), in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: said) { if said.count > 2000 { said = String(said.prefix(2000)) } }
                    .accessibilityLabel("让职绘帮我填")
                HStack(spacing: 12) {
                    Text(helpNote ?? "我拆好填到下面，只管这一段").font(V3.sans(13)).foregroundStyle(GuideStyle.sec).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { Task { await fill() } } label: {
                        Text(filling ? "正在填…" : "填到下面").font(V3.sans(13)).foregroundStyle(said.trimmed.isEmpty || filling ? GuideStyle.ter : V3.txt)
                            .padding(.horizontal, 12).frame(height: 26).background(.white, in: Capsule())
                            .overlay(Capsule().strokeBorder(GuideStyle.line)).contentShape(Capsule())
                    }.buttonStyle(.plain).disabled(said.trimmed.isEmpty || filling || flow.busy)
                }
            }
        }
    }

    private func bind(_ path: WritableKeyPath<GuideModel.Segment, String>) -> Binding<String> {
        Binding(get: { form[keyPath: path] }, set: { value in
            missing = nil
            form[keyPath: path] = path == \GuideModel.Segment.name || path == \GuideModel.Segment.tech ? value.replacingOccurrences(of: "\n", with: " ") : value
            flow.segmentDrafts[draftKey] = form.same(initial) ? nil : form
        })
    }

    /// 一句大白话拆成这一段的各项（`answer:extract`，不写入）；没有技术、介绍两行的类别，拆出来的这两样并回“做了什么”。
    private func fill() async {
        guard !said.trimmed.isEmpty, !filling else { return }
        filling = true; helpNote = nil
        defer { filling = false }
        do {
            let result = try await flow.api.careerRequest(path: "/api/resumes/\(flow.resumeID)/guide/answer:extract", method: "POST", query: [:],
                                                          body: .object(["section": .string("experience"), "group": .string(category.group),
                                                                         "text": .string(said.trimmed), "asked": .string(category.question)]))
            guard let item = result["experience"]?.items.first else { helpNote = "没拆出来，多说一两句：做的什么、什么时候、你负责哪部分。"; return }
            func pick(_ key: String, _ current: String) -> String { item.text(key).nilIfBlank ?? current }
            missing = nil
            form.name = pick("name", form.name); form.role = pick("role", form.role)
            form.start = pick("start", form.start); form.end = pick("end", form.end)
            if category.lines != nil { form.tech = pick("tech", form.tech); form.intro = pick("intro", form.intro) }
            let parts = category.lines != nil ? [item.text("did"), item.text("result")] : [item.text("intro"), item.text("did"), item.text("result"), item.text("tech")]
            form.did = parts.filter { !$0.isEmpty }.joined(separator: "\n").nilIfBlank ?? form.did
            flow.segmentDrafts[draftKey] = form.same(initial) ? nil : form
            filled = true
        } catch {
            helpNote = GuideModel.failureText(ResumeGuideFlow.code(error))
        }
    }

    private func submit() {
        if form.name.trimmed.isEmpty { missing = "name"; return }
        if form.did.trimmed.isEmpty { missing = "did"; return }
        var done = form
        done.did = form.did.split(separator: "\n").map(String.init).filter { !$0.trimmed.isEmpty }.joined(separator: "\n")
        onWrite(done)
    }
}

/// 表单里一项：13 号灰色标签在上，框在下；选填的标签后面灰字“选填”。
struct GuideFormField<Content: View>: View {
    let label: String
    var optional = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(GuideStyle.sec)
                if optional { Text("选填").foregroundStyle(Color(hex: 0xA8A8A1)) }
            }.font(V3.sans(13))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// V3 输入框：白底浅边，圆角 8。
    func guideControl(invalid: Bool = false) -> some View {
        padding(.horizontal, 11).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(invalid ? V3.red : GuideStyle.control))
    }
}

struct GuideControl: View {
    let placeholder: String
    @Binding var text: String
    var maxLength = 100
    var invalid = false
    var multiline = false
    var body: some View {
        TextField("", text: $text, axis: multiline ? .vertical : .horizontal)
            .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(multiline ? 1...4 : 1...1)
            .overlay(alignment: .leading) {
                if text.isEmpty { Text(placeholder).font(V3.sans(14)).foregroundStyle(Color(hex: 0xA8A8A1)).lineLimit(1).allowsHitTesting(false) }
            }
            .onChange(of: text) { if text.count > maxLength { text = String(text.prefix(maxLength)) } }
            .padding(.vertical, 6).guideControl(invalid: invalid)
            .accessibilityLabel(placeholder)
    }
}

/// “做了什么”：一行一条，前面圆点；回车另起一条，空着的一条再按回车不往下加，删到行首并回上一条。
struct GuidePointLines: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Int?

    private var lines: [String] { text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 13) {
                    Circle().fill(line.isEmpty ? Color(hex: 0xA8A8A1) : V3.txt).frame(width: 4, height: 4).padding(.top, 9).padding(.leading, 5)
                    TextField("", text: Binding(get: { lines.indices.contains(index) ? lines[index] : "" }, set: { set(index, $0) }), axis: .vertical)
                        .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).lineSpacing(4)
                        .overlay(alignment: .topLeading) {
                            if line.isEmpty && lines.count == 1 { Text(placeholder).font(V3.sans(14)).foregroundStyle(Color(hex: 0xA8A8A1)).allowsHitTesting(false) }
                        }
                        .focused($focused, equals: index)
                        .onKeyPress(.return) { split(index); return .handled }
                        .onKeyPress(.delete) {
                            guard index > 0, lines[index].isEmpty else { return .ignored }
                            var next = lines; next.remove(at: index); text = next.joined(separator: "\n"); focused = index - 1
                            return .handled
                        }
                        .accessibilityLabel("做了什么，第 \(index + 1) 条")
                }
            }
        }
    }

    private func set(_ index: Int, _ value: String) {
        var next = lines
        guard next.indices.contains(index) else { return }
        // 粘贴进来的几行：去掉自带的序号和圆点
        let typed = value.components(separatedBy: "\n")
        let added = typed.enumerated().map { position, item in
            position == 0 && !next[index].isEmpty ? item : item.replacingOccurrences(of: #"^\s*(?:[-*•·●▪◦]|\d{1,2}[.、．)）])\s*"#, with: "", options: .regularExpression).trimmed
        }.enumerated().filter { !$0.element.isEmpty || $0.offset == 0 }.map(\.element)
        next.replaceSubrange(index...index, with: added)
        text = String(next.joined(separator: "\n").prefix(2000))
        if added.count > 1 { focused = index + added.count - 1 }
    }

    private func split(_ index: Int) {
        guard lines.indices.contains(index), !lines[index].trimmed.isEmpty else { return }
        var next = lines
        next.insert("", at: index + 1)
        text = next.joined(separator: "\n")
        focused = index + 1
    }
}
