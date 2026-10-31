import AppKit
import AVKit
import CoreText
import Foundation
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryQueued: Identifiable {
    let id = UUID()
    var upload: DatasetUpload
    var status = "selected"
    var message = "等待上传"
}
struct DatasetLibraryView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let requireAccount: () -> Void
    @State private var datasets: [DatasetRecord] = []
    @State private var folders: [JSONValue] = []
    @State private var limits: JSONValue = .null
    /// "home" / "files" / 项目 id / "app:<投递 id>"（求职进程项目）。
    @State private var view = "home"
    @State private var tab = "mine"
    @State private var applications: [JSONValue] = []
    @State private var jobSessions: [JSONValue] = []
    @State private var jobState = "loading"
    @State private var storage: JSONValue?
    @State private var draft: String?
    @State private var savingDescription = false
    @State private var addMenu = false
    @State private var picked = Set<String>()
    @State private var pickQuery = ""
    @State private var descriptionText = ""
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var loaded = false
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var refresh = UUID()
    @State private var action: String?
    @State private var target: JSONValue = .null
    @State private var name = ""
    @State private var destination = ""
    @State private var sessions: [JSONValue] = []
    @State private var preview = ""
    @State private var mediaFile: DatasetFile?
    @State private var player: AVPlayer?
    @State private var sheetError: String?
    @State private var queue: [LibraryQueued] = []
    @State private var queueID: UUID?
    @State private var pending = ""
    @State private var active = true
    @State private var loadID = UUID()
    @State private var uploadTask: Task<Void,Never>?
    @State private var batchMode = false
    @State private var hoveredRow: String?
    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var visible: [DatasetRecord] { datasets.filter { item in (view == "files" || item.folder == view) && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query)) } }
    private var jobProjects: [JobProjects.Project] { JobProjects.build(applications,jobSessions,datasets) }
    /// 每份资料所在项目：求职进程优先，其次我的项目，否则「未归入」。
    private var projectLabels: [String: String] {
        var labels = JobProjects.labels(jobProjects)
        for item in datasets where labels[item.id] == nil {
            labels[item.id] = folders.first { $0.text("id") == item.folder }?.text("name") ?? item.raw.text("interview_label").nonEmptyValue ?? "未归入"
        }
        return labels
    }
    private var maximum: Int64 { min(512*1024*1024, Int64(limits["max_media_file_bytes"]?.numberValue ?? 500*1024*1024)) }
    private func request(_ path:String,_ method:String = "GET",_ body:JSONValue? = nil,query:[String:String] = [:]) async throws -> JSONValue {
        let owner = account
        do {
            let result = try await session.api.careerRequest(path:path,method:method,query:query,body:body)
            try Task.checkCancellation(); guard active, !owner.isEmpty, owner == account else { throw CancellationError() }; return result
        } catch { guard active, !owner.isEmpty, owner == account else { throw CancellationError() }; throw error }
    }

    /// 06 V4 资料库（Web `DatasetsPage.tsx`）：首页是「我的项目 / 求职进程」两个标签；「全部文件」是一张总表；
    /// 我的项目里有项目说明和「添加资料」；求职进程项目复用求职进度的资料页。页头固定，正文单独滚动。
    var body: some View {
        GeometryReader { geometry in
            let card = geometry.size.width, gutter = V3Page<EmptyView>.gutter(card: card)
            let width = min(V3Page<EmptyView>.maxWidth(card: card), max(0, card - gutter * 2))
            Group {
                if view.hasPrefix("app:") { jobProject(String(view.dropFirst(4))) }
                else {
                    VStack(alignment:.leading,spacing:0) {
                        header(width:width).padding(.horizontal,gutter)
                        ScrollView {
                            VStack(alignment:.leading,spacing:0) {
                                if loading && !loaded { ProgressView("正在加载资料…").font(V3.sans(13)).frame(maxWidth:.infinity,minHeight:250) }
                                else if !account.isEmpty && !loaded { loadFailed("资料加载失败","请稍后重试。资料和项目都还在，刷新一下试试。") { refresh = UUID() } }
                                else if view == "home" { home }
                                else { fileList }
                                if let error {
                                    HStack(spacing:10) { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red); Spacer(); Button("重新刷新") { refresh = UUID() }.buttonStyle(CareerActionStyle(kind:.link)).disabled(busy) }.padding(.top,16)
                                }
                                if !queue.isEmpty { uploadQueue.padding(.top,24) }
                            }.frame(width:width,alignment:.topLeading).padding(.horizontal,gutter).padding(.bottom,48)
                        }
                    }
                }
            }
        }
        .overlay(alignment:.bottom) { if batchMode && view != "home" { batchBar } }
        .overlay(alignment:.top) { if let notice { toast(notice) } }
        .task(id:account + refresh.uuidString) { active = true; await load(poll:true) }
        .task(id:account + refresh.uuidString + "jobs") { await loadJobs() }
        .task(id:account + "storage" + "\(datasets.count):\(datasets.reduce(0) { $0 + ($1.raw["file_size"]?.numberValue ?? 0) })") { await loadStorage() }
            .onChange(of:account) { _, id in
                player?.pause(); player = nil; mediaFile?.discard(); mediaFile = nil; uploadTask?.cancel(); queue.forEach { $0.upload.discard() }; queue = []; action = nil; selected = []; datasets = []; folders = []; loaded = false; limits = .null; preview = ""; error = nil; sheetError = nil; notice = nil; busy = false; view = "home"; tab = "mine"; query = ""; sessions = []; applications = []; jobSessions = []; jobState = "loading"; storage = nil; draft = nil
                batchMode = false
                if !id.isEmpty && !pending.isEmpty { let next = pending; pending = ""; action = next; name = "" } else { pending = "" }
            }
            .onChange(of:action) { _, value in if value != "media" { player?.pause(); player = nil; mediaFile?.discard(); mediaFile = nil } }
            .onChange(of:view) { draft = nil; addMenu = false }
            .onDisappear { active = false; loadID = UUID(); player?.pause(); player = nil; mediaFile?.discard(); mediaFile = nil; uploadTask?.cancel(); queue.forEach { $0.upload.discard() } }
            .sheet(isPresented:Binding(get:{action != nil},set:{if !$0 && !busy { action = nil }})) { sheet }
            .onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
                guard !busy, DatasetRequest.id(view), !account.isEmpty else { return false }
                let targetFolder = view, owner = account
                for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in guard owner == account else { return }; await enqueue([url],into:targetFolder) } } } }
                return true
            }
    }
    private var folder: String { DatasetRequest.id(view) ? view : "" }
    private var currentFolder: JSONValue? { folders.first { $0.text("id") == view } }
    private var folderName: String { currentFolder?.text("name") ?? "当前项目" }
    private var listedProjects: [JobProjects.Project] { jobProjects.filter { $0.datasetCount > 0 || $0.recordCount > 0 } }
    private var projectCount: Int { folders.count + listedProjects.count }

    /// `.ds-head`：首页标题 → 「N 个项目 · N 份资料 · 存储用量」→ 标签；文件页是面包屑 → 标题 → 摘要 → 说明 → 分隔线。
    private func header(width:CGFloat) -> some View {
        VStack(alignment:.leading,spacing:0) {
            if view == "home" {
                Text("资料库").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height:36)
                HStack(spacing:0) {
                    if loaded { Text("\(projectCount) 个项目 · \(datasets.count) 份资料") }
                    if loaded, let storage {
                        Text(" · 资料 \(JobProjects.size(storage["datasetBytesUsed"]?.numberValue ?? 0)) / \(JobProjects.size(storage["datasetBytesLimit"]?.numberValue ?? 0)) · 音视频 \(JobProjects.size(storage["mediaBytesUsed"]?.numberValue ?? 0)) / \(JobProjects.size(storage["mediaBytesLimit"]?.numberValue ?? 0))")
                    }
                }.font(V3.sans(14)).foregroundStyle(V3.sub).lineLimit(1).frame(height:20).padding(.top,6)
                HStack(alignment:.bottom,spacing:24) {
                    tabButton("mine","我的项目","\(folders.count)")
                    tabButton("jobs","求职进程",jobState == "ready" ? "\(listedProjects.count)" : "")
                    Spacer(minLength:0)
                }.frame(height:44,alignment:.bottom).overlay(alignment:.bottom) { Rectangle().fill(V3.line).frame(height:1) }.padding(.top,14).padding(.bottom,18)
            } else {
                HStack(spacing:12) {
                    Button { go("home") } label:{ HStack(spacing:6) { Image(systemName:"arrow.left").font(.system(size:13)); Text("资料库") }.contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("返回资料库").disabled(busy)
                    Text("/").accessibilityHidden(true)
                    Text(view == "files" ? "全部文件" : "我的项目")
                }.font(V3.sans(16)).foregroundStyle(V3.fnt).frame(height:20).padding(.bottom,12)
                Text(view == "files" ? "全部文件" : folderName).font(V3.serif(28)).foregroundStyle(V3.txt).lineLimit(1).frame(maxWidth:max(0,width - 440),alignment:.leading).frame(height:36)
                Text(folderSubtitle).font(V3.sans(14)).foregroundStyle(V3.sub).frame(height:20).padding(.top,6)
                if view != "files", let currentFolder, loaded { description(currentFolder).padding(.top,14) }
                Rectangle().fill(V3.line).frame(height:1).padding(.top,24)
            }
        }
        .frame(width:width,alignment:.leading)
        .overlay(alignment:.topTrailing) { headerActions.padding(.top,view == "home" ? 10 : 40) }
        .padding(.top,52)
    }
    private func tabButton(_ id:String,_ label:String,_ count:String) -> some View {
        Button { tab = id; query = "" } label:{
            HStack(spacing:6) { Text(label).font(V3.sans(14,weight:.medium)); if !count.isEmpty { Text(count).font(V3.number(11.5,weight:.regular)).foregroundStyle(V3.fnt) } }
                .foregroundStyle(tab == id ? V3.txt : V3.fnt).frame(height:36).contentShape(Rectangle())
                .overlay(alignment:.bottom) { if tab == id { RoundedRectangle(cornerRadius:1).fill(V3.txt).frame(height:2).offset(y:1) } }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == id ? .isSelected : [])
    }
    @ViewBuilder private var headerActions: some View {
        HStack(spacing:10) {
            if view == "home" {
                V3SearchField(text:$query,placeholder:"搜索项目…",width:200)
                Button("全部文件") { go("files") }.buttonStyle(V3ButtonStyle(kind:.ghost)).disabled(batchMode)
                Button("新建项目") { show("createFolder") }.buttonStyle(V3ButtonStyle(kind:.dark,width:96)).disabled(busy || batchMode)
            } else {
                V3SearchField(text:$query,placeholder:"搜索资料…",width:180)
                Button(batchMode ? "取消操作" : "批量操作") { batchMode.toggle(); selected = [] }.buttonStyle(V3ButtonStyle(kind:.ghost,width:92)).disabled(busy)
                if DatasetRequest.id(view) {
                    Button { addMenu = true } label:{ Image(systemName:"plus").font(.system(size:12,weight:.medium)); Text("添加资料") }
                        .buttonStyle(V3ButtonStyle(kind:.dark)).disabled(busy || batchMode || !loaded)
                        .popover(isPresented:$addMenu,arrowEdge:.bottom) {
                            VStack(spacing:2) {
                                V3MenuRow(label:"上传本地文件",systemImage:"square.and.arrow.up") { addMenu = false; pick() }
                                V3MenuRow(label:"从资料库选择",systemImage:"folder") { addMenu = false; openPicker() }
                            }.padding(6).frame(width:184)
                        }
                }
            }
        }
    }
    private var folderSubtitle: String {
        if !loaded { return loading ? "正在加载…" : "" }
        if view == "files" { return "共 \(datasets.count) 份资料，来自 \(projectCount) 个项目" }
        let inside = datasets.filter { $0.folder == view }
        let linked = visible.filter { !$0.raw.text("interview_session_id").isEmpty || !$0.raw.text("interview_label").isEmpty }.count
        return "共 \(inside.count) 份资料" + (linked > 0 ? " · \(linked)份已关联面试" : "")
    }
    /// `.ds-desc`：左侧细竖线引用的项目说明，可就地编辑（最多 500 字，⌘↩ 保存，Esc 取消）。
    @ViewBuilder private func description(_ folder:JSONValue) -> some View {
        let text = folder.text("description")
        if let draft {
            VStack(alignment:.leading,spacing:8) {
                TextEditor(text:Binding(get:{draft},set:{ self.draft = String($0.prefix(500)) }))
                    .font(V3.sans(14)).scrollContentBackground(.hidden).padding(.horizontal,6).padding(.vertical,4)
                    .frame(height:CGFloat(min(6,max(2,draft.split(separator:"\n",omittingEmptySubsequences:false).count))) * 20 + 16)
                    .background(.white,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.cl))
                    .disabled(savingDescription).accessibilityLabel("项目说明")
                    .onKeyPress(.escape) { self.draft = nil; return .handled }
                    .onKeyPress(.return,phases:.down) { press in if press.modifiers.contains(.command) { Task { await saveDescription() }; return .handled }; return .ignored }
                HStack(spacing:8) {
                    Text("\(draft.count)/500").font(V3.number(11,weight:.regular)).foregroundStyle(V3.fnt)
                    Spacer(minLength:0)
                    Button("取消") { self.draft = nil }.buttonStyle(V3ButtonStyle(kind:.ghost,height:28)).disabled(savingDescription)
                    Button(savingDescription ? "正在保存…" : "保存") { Task { await saveDescription() } }.buttonStyle(V3ButtonStyle(kind:.dark,height:28)).disabled(savingDescription)
                }
            }
            .padding(.leading,12).padding(.vertical,2).overlay(alignment:.leading) { Rectangle().fill(V3.fnt2).frame(width:2) }.frame(maxWidth:620,alignment:.leading)
        } else {
            HStack(alignment:.top,spacing:14) {
                Text(text.isEmpty ? "还没有项目说明。写下这个项目是做什么的，方便以后回来时快速想起。" : text)
                    .font(V3.sans(14)).foregroundStyle(text.isEmpty ? V3.fnt : V3.sub).lineHeight(14,20).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading)
                Button(text.isEmpty ? "添加说明" : "编辑说明") { draft = text }.buttonStyle(.plain).font(V3.sans(12,weight:.medium)).foregroundStyle(V3.sub).frame(height:20)
            }
            .padding(.leading,12).padding(.vertical,2).overlay(alignment:.leading) { Rectangle().fill(V3.txt).frame(width:2) }.frame(maxWidth:620,alignment:.leading)
        }
    }
    private func go(_ next:String) { guard !busy else { return }; view = next; if next == "home" { tab = tab } ; selected = []; query = ""; batchMode = false }
    private func relativeDay(_ value:String,withTime:Bool = false) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],from:calendar.startOfDay(for:date),to:calendar.startOfDay(for:Date())).day ?? 0
        let time = self.date(value,format:"HH:mm")
        if days == 0 { return withTime ? "今天 " + time : "今天" }
        if days == 1 { return withTime ? "昨天 " + time : "昨天" }
        return listDate(value)
    }
    private func listDate(_ value:String) -> String {
        guard let date = CareerApplication.date(value) else { return value }
        return self.date(value,format:Calendar.current.component(.year,from:date) == Calendar.current.component(.year,from:Date()) ? "MM-dd" : "yyyy-MM-dd")
    }
    /// 首页正文：我的项目网格（273:172 等比放大，间距 20）或求职进程卡片。
    @ViewBuilder private var home: some View {
        let keyword = query.trimmingCharacters(in:.whitespaces).lowercased()
        if tab == "mine" {
            let shown = sortedFolders.filter { keyword.isEmpty || $0.text("name").lowercased().contains(keyword) }
            if !keyword.isEmpty && shown.isEmpty { noMatch("没有匹配的项目。") }
            else if folders.isEmpty {
                blank(title:"还没有自己的项目",lines:["按一件事把资料放在一起，比如一次秋招、一门复习或一套证书。","在求职进度里上传的录音和笔记，会自动归到「求职进程」。"]) {
                    Text("从常用的开始").font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.trailing,2)
                    ForEach(["秋招简历打磨","面试题库","证书与成绩单"],id:\.self) { item in Button(item) { show("createFolder"); name = item }.buttonStyle(ChipStyle()).disabled(batchMode) }
                }
            } else {
                grid { ForEach(shown,id:\.self) { folderCard($0) }; if keyword.isEmpty { createCard } }
            }
        } else if jobState == "loading" {
            ProgressView().frame(maxWidth:.infinity,minHeight:172)
        } else if jobState == "failed" {
            loadFailed("求职进程加载失败","资料都还在，刷新一下试试。") { Task { await loadJobs() } }
        } else if listedProjects.isEmpty {
            blank(title:"还没有放了资料的求职进程",lines:["在求职进度里给某一轮上传录音、笔记或文件后，","这条投递会出现在这里，按轮次整理好。"],audio:true) {
                Button("打开投递看板") { router?.jump(.section(.jobs)) }.buttonStyle(ChipStyle())
            }
        } else {
            let shown = listedProjects.filter { keyword.isEmpty || $0.name.lowercased().contains(keyword) }
            if shown.isEmpty { noMatch("没有匹配的项目。") } else { grid(aspect:false) { ForEach(shown) { jobCard($0) } } }
        }
    }
    private func noMatch(_ text:String) -> some View { Text(text).font(V3.sans(13)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).padding(.vertical,40) }
    private func grid<Content:View>(aspect:Bool = true,@ViewBuilder _ content:() -> Content) -> some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:273),spacing:20,alignment:.top)],alignment:.leading,spacing:20) { content() }
    }
    private var sortedFolders: [JSONValue] {
        func stamp(_ folder:JSONValue) -> Double {
            max(JobProjects.time(folder.text("updated_at")), datasets.filter { $0.folder == folder.text("id") }.map { JobProjects.time($0.raw.text("created_at")) }.max() ?? 0)
        }
        return folders.sorted { stamp($0) > stamp($1) }
    }
    private func recent(_ folder:String) -> [DatasetRecord] { datasets.filter { $0.folder == folder }.sorted { $0.raw.text("created_at") > $1.raw.text("created_at") } }
    /// `FolderCard`：浅底舞台里排 1–3 张缩略纸张 → 名称 → 「N 份资料 · 最近上传 今天」，右下 ⋯ 菜单。
    private func folderCard(_ item:JSONValue) -> some View {
        let records = recent(item.text("id"))
        let count = item["dataset_count"]?.integer ?? records.count
        let meta = count == 0 ? "还没有资料" : records.first.map { "\(count) 份资料 · 最近上传 " + relativeDay($0.raw.text("created_at")) } ?? "\(count) 份资料"
        return Button { go(item.text("id")) } label:{
            GeometryReader { box in
                let stageW = box.size.width - 14, stageH = box.size.height - 74
                ZStack(alignment:.topLeading) {
                    folderStage(count == 0 ? [] : Array(records.prefix(3))).frame(width:257,height:96)
                        .scaleEffect(min(stageW / 257,stageH / 96)).frame(width:stageW,height:stageH).background(V3.stage).clipShape(RoundedRectangle(cornerRadius:11)).offset(x:7,y:7)
                    Text(item.text("name")).font(V3.sans(14,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(width:max(0,box.size.width - 69),height:17,alignment:.leading)
                        .offset(x:17,y:box.size.height - 53)
                    Text(meta).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).frame(width:max(0,box.size.width - 34),height:18,alignment:.leading).offset(x:17,y:box.size.height - 34)
                }
            }
            .aspectRatio(273.0 / 172.0,contentMode:.fit)
            .background(.white,in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(V3.cl))
            .shadow(color:.black.opacity(0.04),radius:8,x:0,y:4).contentShape(RoundedRectangle(cornerRadius:16))
        }.buttonStyle(.plain).accessibilityLabel("打开项目「\(item.text("name"))」").overlay(alignment:.bottomTrailing) {
            Menu { Button("重命名") { show("renameFolder",item) }; Divider(); Button("删除项目及资料",role:.destructive) { show("deleteFolder",item) } } label:{ LibraryIcon(name:"icon-more",size:14).frame(width:24,height:24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing,12).padding(.bottom,30).disabled(busy)
                .accessibilityLabel("项目「\(item.text("name"))」操作菜单")
        }
    }
    /// `FolderStage`：257×96 的画布，3 张 ±7°，2 张 ±4°，空项目两张淡纸。
    private func folderStage(_ samples:[DatasetRecord]) -> some View {
        ZStack(alignment:.topLeading) {
            switch samples.count {
            case 0: ForEach(0..<2,id:\.self) { index in folderSheet(nil).rotationEffect(.degrees(index == 0 ? -4 : 4)).offset(x:CGFloat(79 + index * 40),y:19) }
            case 1: folderSheet(samples[0]).offset(x:98,y:16)
            case 2: ForEach(0..<2,id:\.self) { index in folderSheet(samples[index]).rotationEffect(.degrees(index == 0 ? -4 : 4)).offset(x:CGFloat(79 + index * 40),y:19) }
            default: ForEach(0..<3,id:\.self) { index in folderSheet(samples[index]).rotationEffect(.degrees(Double(index - 1) * 7)).offset(x:CGFloat(59 + index * 40),y:index == 1 ? 16 : 22) }
            }
        }.frame(width:257,height:96,alignment:.topLeading)
    }
    /// `FolderSheet`：60×78，标题条 + 四行灰条 + 左下格式色块；没有资料时是淡色的空纸。
    private func folderSheet(_ item:DatasetRecord?) -> some View {
        let ghost = item == nil
        return ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:4).fill(ghost ? Color.white.opacity(0.72) : .white)
                .overlay(RoundedRectangle(cornerRadius:4).stroke(ghost ? V3.txt.opacity(0.08) : V3.cl))
                .shadow(color:.black.opacity(ghost ? 0.04 : 0.07),radius:ghost ? 3 : 4,y:ghost ? 2 : 3)
            RoundedRectangle(cornerRadius:1).fill(ghost ? V3.txt.opacity(0.16) : V3.txt).frame(width:25,height:4).offset(x:8,y:11)
            ForEach([(23,43),(34,43),(44,43),(54,24)],id:\.0) { y,w in RoundedRectangle(cornerRadius:1).fill(ghost ? V3.txt.opacity(0.07) : V3.line).frame(width:CGFloat(w),height:3).offset(x:8,y:CGFloat(y)) }
            if let item {
                let tone = formatTone(item)
                Text(tone.label).font(V3.number(7,weight:.bold)).foregroundStyle(.white).padding(.horizontal,4).frame(height:12).background(tone.color,in:RoundedRectangle(cornerRadius:3)).offset(x:8,y:55)
            }
        }.frame(width:60,height:78,alignment:.topLeading).clipShape(RoundedRectangle(cornerRadius:4))
    }
    private var createCard: some View {
        Button { show("createFolder") } label:{
            VStack(spacing:0) {
                LibraryIcon(name:"icon-plus",size:16).frame(width:36,height:36).background(V3.field,in:Circle())
                Text("新建项目").font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt).frame(height:16).padding(.top,12)
                Text("把同一件事的资料放在一起").font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height:13).padding(.top,6)
            }.padding(.bottom,11).frame(maxWidth:.infinity,maxHeight:.infinity).aspectRatio(273.0 / 172.0,contentMode:.fit).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius:16).stroke(V3.fnt2,style:StrokeStyle(lineWidth:1,dash:[4,3])))
        }.buttonStyle(.plain).accessibilityLabel("新建项目").disabled(busy || batchMode)
    }
    /// 求职进程卡（06.V4-1b）：公司与岗位 → 文字阶段链 → 下一场 / 状态与资料数；只有 Offer 用蓝色。
    private func jobCard(_ project:JobProjects.Project) -> some View {
        let company = project.application.text("company_name_snapshot").trimmingCharacters(in:.whitespaces)
        let role = project.application.text("job_title_snapshot").trimmingCharacters(in:.whitespaces)
        let next = project.next
        let nextDate = next?.date.flatMap(CareerApplication.date).map { String(format:"%02d-%02d",Calendar.current.component(.month,from:$0),Calendar.current.component(.day,from:$0)) } ?? ""
        return Button { go("app:" + project.id) } label:{
            VStack(alignment:.leading,spacing:14) {
                HStack(spacing:10) {
                    Text(project.monogram).font(V3.serif(14)).foregroundStyle(V3.sub).frame(width:32,height:32).background(V3.stage,in:RoundedRectangle(cornerRadius:8))
                    VStack(alignment:.leading,spacing:2) {
                        Text(company.isEmpty ? project.name : company).font(V3.sans(14,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height:19)
                        if !company.isEmpty && !role.isEmpty { Text(role).font(V3.sans(12)).foregroundStyle(V3.sub).lineLimit(1).frame(height:17) }
                    }
                }
                HStack(alignment:.firstTextBaseline,spacing:0) {
                    ForEach(Array(project.chain.enumerated()),id:\.offset) { index,node in
                        if index > 0 { Text("›").font(V3.number(11,weight:.regular)).foregroundStyle(V3.fnt).padding(.horizontal,5) }
                        if let node {
                            let focus = node.key == project.focusKey
                            Text(node.label).font(V3.sans(12,weight:focus || node.state == .offer ? .medium : .regular))
                                .foregroundStyle(node.state == .offer ? V3.blue : focus ? V3.txt : node.state == .upcoming ? V3.fnt : V3.sub)
                        } else { Text("…").font(V3.sans(12)).foregroundStyle(V3.sub) }
                    }
                }.lineLimit(1).frame(height:18)
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    if let next { Text(nextDate.isEmpty ? "下一场 \(next.label)" : "下一场 \(nextDate) \(next.label)").foregroundStyle(V3.sub).lineLimit(1) }
                    else { Text(project.statusLabel).foregroundStyle(project.offer ? V3.blue : V3.sub).lineLimit(1) }
                    Spacer(minLength:0)
                    Text(project.materialSummary).foregroundStyle(V3.fnt)
                }.font(V3.sans(11.5)).frame(height:16)
            }
            .padding(.horizontal,17).padding(.top,17).padding(.bottom,15).frame(maxWidth:.infinity,alignment:.leading)
            .background(project.archived ? Color(hex:0xFBFBFA) : .white,in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(V3.cl))
            .opacity(project.archived ? 0.6 : 1).contentShape(RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain).accessibilityLabel("打开求职进程项目「\(project.name)」")
    }
    /// 求职进程项目：和求职进度里的「资料」同一页，左上回资料库，右上多一个「打开求职进度 ↗」。
    @ViewBuilder private func jobProject(_ id:String) -> some View {
        if let project = jobProjects.first(where:{ $0.id == id }) {
            CareerApplicationDetailView(application:CareerApplication(project.application),api:session.api,back:{ view = "home"; tab = "jobs"; Task { await loadJobs(background:true) } },
                                        perform:{ _,app in router?.jump(.application(app.id)) },libraryMaterials:true).id(id)
        } else if jobState == "loading" {
            ProgressView("正在加载项目…").font(V3.sans(13)).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            VStack(spacing:16) {
                Text(jobState == "failed" ? "求职进程加载失败" : "这个求职进程不存在或已删除").font(V3.sans(17,weight:.medium)).foregroundStyle(V3.txt)
                Button("返回资料库") { view = "home"; tab = "jobs" }.buttonStyle(V3ButtonStyle(kind:.ghost))
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    /// `ProjectsEmpty`：居中插图 + 标题 + 两行说明 + 轻量操作，不放黑色按钮。
    private func blank<Actions:View>(title:String,lines:[String],audio:Bool = false,@ViewBuilder actions:() -> Actions) -> some View {
        VStack(spacing:0) {
            emptyArt(audio:audio).frame(width:200,height:112)
            Text(title).font(V3.sans(17,weight:.medium)).foregroundStyle(V3.txt).frame(height:24).padding(.top,20)
            VStack(spacing:0) { ForEach(lines,id:\.self) { Text($0).frame(height:21) } }.font(V3.sans(13)).foregroundStyle(V3.sub).padding(.top,8)
            HStack(spacing:8) { actions() }.padding(.top,24)
        }.frame(maxWidth:.infinity).padding(.top,72).padding(.bottom,40)
    }
    /// `ProjectsEmptyArt`：三张小文件，求职进程多一张音频卡。
    private func emptyArt(audio:Bool) -> some View {
        ZStack(alignment:.topLeading) {
            miniDoc("PDF",V3.orange).rotationEffect(.degrees(-8)).offset(x:18,y:22)
            miniDoc("DOCX",V3.blue).offset(x:70,y:12)
            miniDoc("PDF",V3.orange).rotationEffect(.degrees(7)).offset(x:122,y:20)
            if audio {
                ZStack(alignment:.topLeading) {
                    RoundedRectangle(cornerRadius:8).fill(.white).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.cl)).shadow(color:.black.opacity(0.06),radius:8,y:6)
                    Circle().fill(V3.txt).frame(width:12,height:12).offset(x:8,y:9)
                    ForEach([(26,14,3),(31,10,9),(36,9,12),(41,10,10),(46,12,5),(51,13,4),(56,13,5)],id:\.0) { x,y,h in RoundedRectangle(cornerRadius:1).fill(V3.sub).frame(width:2,height:CGFloat(h)).offset(x:CGFloat(x),y:CGFloat(y)) }
                }.frame(width:70,height:30,alignment:.topLeading).offset(x:140,y:76)
            }
        }.frame(width:200,height:112,alignment:.topLeading).accessibilityHidden(true)
    }
    private func miniDoc(_ tag:String,_ color:Color) -> some View {
        ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:5).fill(.white).overlay(RoundedRectangle(cornerRadius:5).stroke(V3.cl)).shadow(color:.black.opacity(0.06),radius:8,y:6)
            RoundedRectangle(cornerRadius:2).fill(V3.sk2).frame(width:34,height:4).offset(x:7,y:9)
            RoundedRectangle(cornerRadius:2).fill(V3.line).frame(width:43,height:3).offset(x:7,y:18)
            RoundedRectangle(cornerRadius:2).fill(V3.line).frame(width:31,height:3).offset(x:7,y:25)
            Text(tag).font(tag.count > 2 ? V3.number(7.5,weight:.bold) : V3.sans(7.5,weight:.bold)).foregroundStyle(.white).padding(.horizontal,7).frame(height:13).background(color,in:RoundedRectangle(cornerRadius:3)).offset(x:7,y:60)
        }.frame(width:62,height:80,alignment:.topLeading).clipShape(RoundedRectangle(cornerRadius:5))
    }
    /// `datasetFormatTone`: PDF red, MD green, DOCX blue, TXT grey, audio/video orange.
    private func formatTone(_ item:DatasetRecord) -> (label:String,color:Color,tint:Color) {
        let label = String((item.format.isEmpty ? "FILE" : item.format).prefix(4))
        if item.media { return (label,V3.orange,Color(hex:0xFBF1E6)) }
        switch label {
        case "PDF": return (label,V3.red,Color(hex:0xFBEEEE))
        case "MD": return (label,V3.green,Color(hex:0xECF5EF))
        case "DOCX": return (label,V3.blue,Color(hex:0xEDF2FC))
        default: return (label,V3.sub,V3.field)
        }
    }
    private func formatIcon(_ item:DatasetRecord,tinted:Bool = true) -> some View {
        let tone = formatTone(item)
        return Text(tone.label).font(V3.number(tone.label.count > 3 ? 7 : 8,weight:.bold)).foregroundStyle(tone.color)
            .frame(width:32,height:32).background(tinted ? tone.tint : V3.field,in:RoundedRectangle(cornerRadius:8)).accessibilityHidden(true)
    }
    private func loadFailed(_ title:String,_ subtitle:String,retry:@escaping () -> Void) -> some View {
        V3EmptyCard(title:title,message:subtitle,stageHeight:112) { Image(systemName:"exclamationmark.arrow.triangle.2.circlepath").font(.system(size:36,weight:.ultraLight)).foregroundStyle(V3.fnt2) } actions: {
            Button(action:retry) { Image(systemName:"arrow.clockwise").font(.system(size:11)); Text("重新加载") }.buttonStyle(V3ButtonStyle(kind:.ghost,height:34,width:96)).disabled(busy)
        }.frame(maxWidth:.infinity).padding(.top,115)
    }
    /// 06.2 列表：格式 / 名称 + 状态 / 关联（全部文件里是所在项目）/ 大小 / 上传日期（或重试）/ ⋯，批量模式换成勾选框。
    @ViewBuilder private var fileList: some View {
        let inside = view == "files" ? datasets : datasets.filter { $0.folder == view }
        if view != "files" && inside.isEmpty {
            blank(title:"还没有资料",lines:["把与这个项目相关的文件直接拖到这里，","或者从本地上传、从资料库里挑几份移进来。"]) {
                Button("上传本地文件") { pick() }.buttonStyle(ChipStyle()).disabled(batchMode)
                Button("从资料库选择") { openPicker() }.buttonStyle(ChipStyle()).disabled(batchMode)
            }
        } else {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:0) {
                    Text("名称").frame(maxWidth:.infinity,alignment:.leading)
                    Text(view == "files" ? "所在项目" : "关联").frame(width:190,alignment:.leading)
                    Text("大小").frame(width:66,alignment:.trailing)
                    Text("上传日期").frame(width:144,alignment:.trailing)
                    Group {
                        if batchMode {
                            Toggle("全选当前列表",isOn:Binding(get:{!visible.isEmpty && visible.allSatisfy{selected.contains($0.id)}},set:{if $0 { selected.formUnion(visible.map(\.id)) } else { selected.subtract(visible.map(\.id)) }}))
                                .labelsHidden().toggleStyle(.checkbox).disabled(visible.isEmpty || busy)
                        } else { Color.clear }
                    }.frame(width:42,alignment:.trailing)
                }
                .font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height:18).padding(.leading,12).padding(.trailing,10).padding(.top,22).frame(height:46,alignment:.top)
                .overlay(alignment:.bottom) { Rectangle().fill(V3.line).frame(height:1) }
                if visible.isEmpty { Text(query.isEmpty ? "还没有资料。" : "没有匹配的资料。").font(V3.sans(13)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).padding(.vertical,40) }
                else {
                    VStack(spacing:6) {
                        ForEach(Array(visible.enumerated()),id:\.element.id) { index,item in
                            fileRow(item).overlay(alignment:.top) { if index > 0 && hoveredRow != item.id && hoveredRow != visible[index - 1].id { Rectangle().fill(V3.line).frame(height:1).padding(.leading,68).offset(y:-3.5) } }
                        }
                    }.padding(.top,5)
                }
                if DatasetRequest.id(view) {
                    Button { pick() } label:{
                        VStack(spacing:4) {
                            HStack(spacing:8) { Image(systemName:"arrow.up.doc").font(.system(size:13)); Text("拖入文件，或点击上传到「\(folderName)」") }.font(V3.sans(12.5,weight:.medium)).foregroundStyle(V3.sub).frame(height:15)
                            Text("PDF、DOCX、Markdown、TXT 最大 \(JobProjects.size(limits["max_file_bytes"]?.numberValue ?? 20*1024*1024))；音视频最大 \(JobProjects.size(Double(maximum)))")
                                .font(V3.sans(10.5)).foregroundStyle(V3.fnt).frame(height:13)
                        }.frame(maxWidth:.infinity).frame(height:52).contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius:10).stroke(V3.fnt2,style:StrokeStyle(lineWidth:1,dash:[4,3])))
                    }.buttonStyle(.plain).padding(.top,16).disabled(busy || batchMode || !loaded)
                }
            }
        }
    }
    /// `datasetRowMeta`: format name when ready, otherwise the status (blue while processing, red when failed).
    private func rowMeta(_ item:DatasetRecord) -> (String,Color) {
        if item.media {
            if item.raw.text("upload_status") == "failed" { return ("上传失败",V3.red) }
            if item.raw.text("upload_status") == "uploading" { return ("正在上传…",V3.blue) }
            if item.raw.text("asset_kind") == "audio" {
                let state = ["queued":"等待转写","processing":"正在转写…","failed":"转写失败"][item.raw.text("parse_status")] ?? (item.raw["has_transcript"]?.bool == true ? "转写完成" : "点击播放")
                return ("音频 · " + state,V3.fnt)
            }
            return ("视频 · 点击下载",V3.fnt)
        }
        if item.raw.text("parse_status") == "failed" || item.raw.text("upload_status") == "failed" {
            let reason = item.raw.text("failure_reason")
            let label = ["format_unsupported":"文件格式不受支持","content_invalid":"文件内容无效","size_exceeded":"文件内容超出解析限制","service_unavailable":"解析服务暂不可用","timeout":"解析超时","quota_exceeded":"当前资料数量已达上限"][reason]
            return (label.map { "解析失败 · " + $0 } ?? "解析失败",V3.red)
        }
        if item.raw.text("parse_status") == "queued" { return ("等待解析",V3.blue) }
        if item.busy { return ("正在解析…",V3.blue) }
        return (["MD":"Markdown","PDF":"PDF","DOCX":"Word","TXT":"纯文本"][item.format] ?? item.format,V3.fnt)
    }
    private func fileRow(_ item:DatasetRecord) -> some View {
        let meta = rowMeta(item)
        let failed = meta.1 == V3.red && !item.media
        return HStack(spacing:0) {
            formatIcon(item)
            VStack(alignment:.leading,spacing:4) {
                Text(item.displayName).font(V3.sans(14,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height:20).help(item.name)
                Text(meta.0).font(V3.sans(12)).foregroundStyle(meta.1).lineLimit(1).frame(height:18)
            }.padding(.horizontal,12).padding(.top,9).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            HStack(spacing:5) {
                if view == "files" {
                    if item.raw.text("interview_session_id").isEmpty { LibraryIcon(name:"icon-folder",size:13) } else { CareerIcon(name:"brief",size:13,template:true).foregroundStyle(V3.sub) }
                    Text(projectLabels[item.id] ?? "未归入").lineLimit(1)
                } else if !item.raw.text("interview_label").isEmpty {
                    CareerIcon(name:"calendar",size:13,template:true).foregroundStyle(V3.sub)
                    Text("面试 · " + item.raw.text("interview_label")).lineLimit(1)
                }
            }.font(V3.sans(12)).foregroundStyle(V3.sub).frame(width:190,alignment:.leading)
            Text(JobProjects.size(item.raw["file_size"]?.numberValue ?? 0)).font(V3.number(12,weight:.regular)).foregroundStyle(V3.sub).frame(width:66,alignment:.trailing)
            Group {
                if failed && item.retryable { Button("重试") { Task { await mutate("/api/datasets/" + item.id + "/retry","POST") } }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(V3.txt).disabled(busy || batchMode) }
                else { Text(listDate(item.raw.text("created_at"))).font(V3.number(12,weight:.regular)).foregroundStyle(V3.sub) }
            }.frame(width:144,alignment:.trailing)
            Group {
                if batchMode {
                    Toggle("选择「\(item.name)」",isOn:Binding(get:{selected.contains(item.id)},set:{if $0 {selected.insert(item.id)} else {selected.remove(item.id)}})).labelsHidden().toggleStyle(.checkbox).disabled(busy)
                } else {
                    Menu {
                        Button(item.raw.text("asset_kind") == "audio" ? "播放音频" : item.media ? "下载文件" : "查看文件") { open(item) }.disabled(!item.ready)
                        Button("重命名") { show("rename",item.raw) }
                        Button("移动到项目") { selected = [item.id]; show("move") }
                        Button("管理关联") { show("associate",item.raw); Task { await loadSessions() } }.disabled(item.raw.text("upload_status") != "succeeded")
                        if item.retryable { Button("重新解析") { Task { await mutate("/api/datasets/" + item.id + "/retry","POST") } } }
                        Divider()
                        Button("删除资料",role:.destructive) { selected = [item.id]; show("deleteBatch") }.disabled(item.busy)
                    } label:{ Image(systemName:"ellipsis").font(.system(size:13)).foregroundStyle(V3.fnt).frame(width:28,height:28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(busy).accessibilityLabel("打开「\(item.displayName)」操作菜单")
                }
            }.frame(width:42,alignment:.trailing)
        }
        .padding(.leading,12).padding(.trailing,10).frame(height:54)
        .background(RoundedRectangle(cornerRadius:8).fill(hoveredRow == item.id ? Color(hex:0xF6F6F3) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in hoveredRow = inside ? item.id : (hoveredRow == item.id ? nil : hoveredRow) }
        .onTapGesture { if batchMode { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } } else if item.ready { open(item) } }
        .accessibilityElement(children:.contain)
        .accessibilityLabel(item.ready && !batchMode ? (item.raw.text("asset_kind") == "audio" ? "播放「\(item.displayName)」" : item.media ? "下载「\(item.displayName)」" : "打开「\(item.displayName)」解析预览") : item.displayName)
        .accessibilityAction { if item.ready && !batchMode { open(item) } }
    }
    /// `.ds-batch-bar`: floating bar while selecting several datasets.
    private var batchBar: some View {
        HStack(spacing:14) {
            Toggle(isOn:Binding(get:{!visible.isEmpty && visible.allSatisfy{selected.contains($0.id)}},set:{if $0 { selected.formUnion(visible.map(\.id)) } else { selected.subtract(visible.map(\.id)) }})) { Text("全选").font(V3.sans(13)).foregroundStyle(V3.txt) }
                .toggleStyle(.checkbox).disabled(visible.isEmpty || busy)
            HStack(spacing:0) { Text("已选 ").foregroundStyle(V3.sub); Text("\(selected.count)").font(V3.number(13)).foregroundStyle(V3.txt); Text(" 项").foregroundStyle(V3.sub) }.font(V3.sans(13))
            Rectangle().fill(V3.line).frame(width:1,height:20)
            Button { show("move") } label:{ LibraryIcon(name:"icon-folder",size:13); Text("移动到项目") }.buttonStyle(V3ButtonStyle(kind:.ghost,height:30)).disabled(selected.isEmpty || busy)
            Button { show("deleteBatch") } label:{ Image(systemName:"trash").font(.system(size:11)); Text("删除") }.buttonStyle(V3ButtonStyle(kind:.danger,height:30)).disabled(selected.isEmpty || busy)
            Rectangle().fill(V3.line).frame(width:1,height:20)
            Button { batchMode = false; selected = [] } label:{ Image(systemName:"xmark").font(.system(size:12,weight:.medium)).foregroundStyle(V3.sub).frame(width:28,height:28) }
                .buttonStyle(.plain).accessibilityLabel("取消选择").help("取消选择并退出批量")
        }
        .padding(.horizontal,16).frame(height:48)
        .background(.white,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(V3.cl))
        .shadow(color:.black.opacity(0.10),radius:16,y:6)
        .padding(.bottom,28)
    }
    private func show(_ kind:String,_ item:JSONValue = .null) {
        guard !busy else { return }; if account.isEmpty { pending = kind == "createFolder" ? kind : "createFolder"; requireAccount(); return }
        target = item; action = kind; sheetError = nil; preview = ""; name = kind == "renameFolder" ? item.text("name") : kind == "createFolder" ? "" : item.text("file_name"); descriptionText = ""; pickQuery = ""; picked = []
        destination = kind == "associate" ? item.text("interview_session_id") : kind == "move" ? "" : folders.first?.text("id") ?? ""
    }
    /// `.v3-dialog`：标题 20 / 29 行高、说明距标题 5；底栏 88 高带分隔线。窄弹窗（≤500）按钮靠左，宽弹窗靠右。
    private var sheet: some View {
        let width: CGFloat = ["preview","media"].contains(action ?? "") ? 820 : action == "associate" ? 540 : ["move","pick"].contains(action ?? "") ? 520 : 440
        let narrow = width <= 500, inset: CGFloat = narrow ? 20 : 32
        return VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:0) {
                Text(sheetTitle).font(V3.serif(20)).foregroundStyle(V3.txt).lineLimit(1).frame(height:29).padding(.trailing,36)
                if let description = sheetDescription {
                    Text(description).font(V3.sans(14)).foregroundStyle(V3.sub).lineLimit(["associate","pick","move"].contains(action ?? "") ? 1 : nil).lineHeight(14,15).fixedSize(horizontal:false,vertical:true).padding(.top,5)
                }
                VStack(alignment:.leading,spacing:0) { sheetContent }.padding(.top,["preview","media"].contains(action ?? "") ? 0 : action == "pick" ? 16 : 20)
                if let sheetError, !["preview","media"].contains(action ?? "") { Text(sheetError).foregroundStyle(V3.red).font(V3.sans(11.5)).padding(.top,12) }
            }
            .padding(.horizontal,inset).padding(.top,narrow ? 24 : 28).padding(.bottom,["preview","media"].contains(action ?? "") ? 32 : action == "associate" ? 24 : 32)
            if !["preview","media"].contains(action ?? "") {
                Rectangle().fill(V3.line).frame(height:1)
                HStack(spacing:10) {
                    if action == "associate" && !target.text("interview_session_id").isEmpty {
                        Button("取消关联") { Task { await save(unlink:true) } }.buttonStyle(.plain).font(V3.sans(12,weight:.medium)).foregroundStyle(V3.red).disabled(busy)
                    }
                    if !narrow { Spacer(minLength:0) }
                    Button("取消") { action = nil }.buttonStyle(V3ButtonStyle(kind:.ghost,height:36,width:80)).disabled(busy)
                    Button(busy ? "处理中…" : confirmLabel) { Task { await save() } }
                        .buttonStyle(V3ButtonStyle(kind:["deleteFolder","deleteBatch"].contains(action ?? "") ? .danger : .dark,height:36,width:action == "associate" ? 88 : nil)).disabled(busy || loading || confirmDisabled)
                    if narrow { Spacer(minLength:0) }
                }.padding(.horizontal,inset).frame(height:88)
            }
        }
        .frame(width:width).frame(maxHeight:740)
        .overlay(alignment:.topTrailing) {
            Button { action = nil } label:{ Image(systemName:"xmark").font(.system(size:13,weight:.medium)).foregroundStyle(V3.fnt).frame(width:28,height:28).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("关闭").disabled(busy).padding(.top,narrow ? 20 : 26).padding(.trailing,narrow ? 16 : 26)
        }
        .interactiveDismissDisabled(busy)
    }
    private var sheetTitle: String {
        switch action {
        case "deleteFolder": return "删除项目「\(target.text("name"))」及其中的资料？"
        case "move": return selected.count == 1 ? "移动资料到项目" : "移动 \(selected.count) 份资料到项目"
        case "preview", "media": return target.text("file_name")
        case "deleteBatch": return selected.count == 1 ? "永久删除「\(datasets.first { selected.contains($0.id) }?.name ?? "资料")」？" : "永久删除所选资料（\(selected.count) 份）？"
        default: return ["createFolder":"新建项目","renameFolder":"重命名项目","rename":"重命名资料","associate":"管理关联","pick":"从资料库选择","uploadRename":"保留两份","replace":"替换现有文档？"][action ?? ""] ?? "资料库"
        }
    }
    private var sheetDescription: String? {
        let one = datasets.first { selected.contains($0.id) }?.name ?? ""
        return ["createFolder":"把同一件事的资料放进一个项目，例如一次面试冲刺或一份作品集。","renameFolder":"只修改项目名称，项目内的资料不受影响。","rename":"只修改资料显示名称，不改变文件格式或已保存的内容。",
                "deleteFolder":(target["dataset_count"]?.integer ?? 0) > 0 ? "项目里的 \(target["dataset_count"]?.integer ?? 0) 份资料会和项目一起永久删除（包括源文件和解析结果），无法恢复。想保留的资料，请先移到其他项目。" : "这个项目里没有资料，删除后无法恢复。",
                "move":selected.count == 1 ? "「\(one)」 · 选择目标项目" : "已选择 \(selected.count) 份资料 · 选择目标项目",
                "associate":"「\(target.text("file_name"))」可以关联到一场面试，关联后在求职记录里也能看到它。",
                "pick":"选中的资料会移到「\(folderName)」。"][action ?? ""]
    }
    private var confirmLabel: String {
        ["createFolder":"创建项目","rename":"保存名称","deleteFolder":(target["dataset_count"]?.integer ?? 0) > 0 ? "连同资料一起删除" : "确认删除","deleteBatch":selected.count == 1 ? "永久删除" : "永久删除所选","replace":"确认替换","move":"确定移动",
         "pick":picked.isEmpty ? "移入项目" : "移入 \(picked.count) 份"][action ?? ""] ?? "保存"
    }
    private var confirmDisabled: Bool {
        switch action {
        case "pick": return picked.isEmpty
        case "move": return !DatasetRequest.id(destination)
        case "associate": return destination.isEmpty || destination == target.text("interview_session_id")
        default: return false
        }
    }
    /// 从资料库选择：一份资料只属于一个项目，关联了面试的资料归求职进程，不出现在候选里。
    private var pickCandidates: [DatasetRecord] {
        datasets.filter { $0.folder != view && $0.raw.text("interview_session_id").isEmpty && $0.raw.text("upload_status") == "succeeded" }
    }
    private func openPicker() { guard DatasetRequest.id(view) else { return }; show("pick") }
    @ViewBuilder private var sheetContent: some View {
        if ["createFolder","renameFolder","rename","uploadRename"].contains(action ?? "") {
            VStack(alignment:.leading,spacing:8) {
                Text(["createFolder":"项目名称","renameFolder":"项目名称"][action ?? ""] ?? "资料名称").font(V3.sans(14,weight:.medium)).foregroundStyle(V3.sub).frame(height:20)
                TextField("",text:Binding(get:{name},set:{ name = action == "createFolder" || action == "renameFolder" ? String($0.prefix(64)) : $0 }),prompt:Text(action == "createFolder" ? "例如：系统设计复习、英文简历与求职信" : "").foregroundStyle(V3.fnt2)).textFieldStyle(.plain).font(V3.sans(13))
                    .padding(.horizontal,12).frame(height:40).background(.white,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.cl))
                    .onSubmit { Task { await save() } }.disabled(busy)
                if action == "createFolder" {
                    Text("项目说明（可选）").font(V3.sans(14,weight:.medium)).foregroundStyle(V3.sub).frame(height:20).padding(.top,12)
                    TextEditor(text:Binding(get:{descriptionText},set:{ descriptionText = String($0.prefix(500)) })).font(V3.sans(13)).scrollContentBackground(.hidden).scrollIndicators(.never)
                        .padding(.horizontal,6).padding(.vertical,4).frame(height:40).background(.white,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.cl))
                        .disabled(busy).accessibilityLabel("项目说明")
                }
            }
        }
        else if action == "move" {
            Text("选择目标分类").font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height:13).padding(.bottom,9)
            pickList(maxHeight:228) {
                let current = selected.count == 1 ? datasets.first { selected.contains($0.id) }?.folder : nil
                let others = folders.filter { $0.text("id") != current }
                if others.isEmpty { Text("还没有其他项目").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                ForEach(others,id:\.self) { item in
                    pickRow(checked:destination == item.text("id"),action:{ destination = item.text("id") }) {
                        LibraryIcon(name:"icon-folder",size:14); Text(item.text("name")).lineLimit(1); Spacer(minLength:0)
                        Text("\(item["dataset_count"]?.integer ?? 0) 份").font(V3.number(11.5,weight:.regular)).foregroundStyle(V3.fnt)
                    }
                }
            }
        }
        else if action == "pick" {
            V3SearchField(text:$pickQuery,placeholder:"搜索资料…",width:nil,height:30).padding(.bottom,10)
            let shown = pickCandidates.filter { pickQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(pickQuery) }
            pickList(maxHeight:300) {
                if shown.isEmpty { Text(pickCandidates.isEmpty ? "资料库里没有可以移入的资料" : "没有匹配的资料。").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                ForEach(shown) { item in
                    let on = picked.contains(item.id)
                    pickRow(checked:on,height:48,action:{ if on { picked.remove(item.id) } else { picked.insert(item.id) } }) {
                        formatIcon(item); Text(item.name).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                        Text(projectLabels[item.id] ?? "未归入").font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1).frame(maxWidth:140,alignment:.trailing)
                        RoundedRectangle(cornerRadius:4).fill(on ? V3.txt : .clear).overlay(RoundedRectangle(cornerRadius:4).stroke(on ? V3.txt : V3.fnt2,lineWidth:1.5))
                            .overlay { if on { Image(systemName:"checkmark").font(.system(size:9,weight:.bold)).foregroundStyle(.white) } }.frame(width:16,height:16)
                    }
                }
            }
        }
        else if action == "deleteFolder" { EmptyView() }
        else if action == "deleteBatch" {
            Text(selected.count == 1 ? "删除后将移除源文件、解析结果和资料记录，且无法恢复。" : "将删除所选 \(selected.count) 份资料，移除源文件、解析结果和资料记录，且无法恢复。").font(V3.sans(13)).foregroundStyle(V3.sub).fixedSize(horizontal:false,vertical:true)
            if selected.count > 1 { ScrollView { VStack(alignment:.leading,spacing:8) { ForEach(datasets.filter{selected.contains($0.id)}) { Text($0.name).font(V3.sans(12)).foregroundStyle(V3.sub) } } }.frame(maxHeight:160) }
        }
        else if action == "associate" {
            associateArt.frame(maxWidth:.infinity).frame(height:96).background(V3.stage,in:RoundedRectangle(cornerRadius:11)).padding(.top,3)
            V3SearchField(text:$pickQuery,placeholder:"搜索公司、岗位或轮次…",width:nil,height:38).padding(.top,20)
            HStack { Text("选择要关联的面试"); Spacer(); Text("一份资料只能关联一场") }.font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height:13).padding(.top,20).padding(.bottom,11)
            let current = target.text("interview_session_id")
            let keyword = pickQuery.lowercased()
            let shown = sessions.sorted { a,b in a.text("id") == current ? true : b.text("id") == current ? false : a.text("start_at") > b.text("start_at") }
                .filter { keyword.isEmpty || "\($0.text("company_name")) \($0.text("job_title")) \($0.text("stage_label"))".lowercased().contains(keyword) }
            pickList(height:240) {
                if loading && sessions.isEmpty { Text("正在读取面试…").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                else if shown.isEmpty { Text(keyword.isEmpty ? "还没有面试安排，可以先在投递看板里添加" : "没有匹配的面试").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                ForEach(shown,id:\.self) { item in
                    let on = destination == item.text("id")
                    pickRow(checked:on,height:50,action:{ destination = item.text("id") }) {
                        Circle().fill(on ? V3.txt : .white).overlay(Circle().stroke(on ? V3.txt : V3.fnt2)).overlay { if on { Circle().fill(.white).frame(width:6,height:6) } }.frame(width:16,height:16)
                        VStack(alignment:.leading,spacing:5) {
                            Text("\(item.text("company_name")) · \(item.text("job_title"))").font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1)
                            Text(sessionMeta(item)).font(V3.number(11,weight:.regular)).foregroundStyle(V3.fnt).lineLimit(1)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if item.text("id") == current { Text("当前").font(V3.sans(10.5,weight:.medium)).foregroundStyle(V3.sub).padding(.horizontal,8).frame(height:22).overlay(Capsule().stroke(V3.cl)) }
                    }
                }
            }
        }
        else if action == "preview" || action == "media" {
            previewMeta
            if action == "media" { mediaPreview }
            else {
                ZStack {
                    if loading { VStack(spacing:12) { ProgressView(); Text("正在读取解析结果…") }.font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
                    else if preview.isEmpty { VStack(spacing:12) { if let sheetError { Text(sheetError) }; Button { Task { await loadPreview() } } label:{ Image(systemName:"arrow.clockwise").font(.system(size:11)); Text("重新加载") }.buttonStyle(V3ButtonStyle(kind:.ghost)) }.font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
                    else { ScrollView { NativeMarkdownView(source:preview).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,32).padding(.vertical,28) } }
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity).background(.white,in:RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).stroke(V3.cl))
                .padding(24).frame(height:612).background(V3.stage,in:RoundedRectangle(cornerRadius:11)).padding(.top,20)
            }
        }
        else if action == "replace" { Text("确认使用当前上传文件替换「\(target.text("file_name"))」？旧原文件和解析结果会被删除，不可恢复；保留资料 ID、文件夹和面试关联。") }
    }
    private func load(poll:Bool = false) async {
        let generation = UUID(); loadID = generation
        guard !account.isEmpty else { loaded = true; return }; loading = true; error = nil
        do {
            repeat {
                async let files = request("/api/datasets")
                async let groups = request("/api/datasets/folders")
                let (data,group) = try await (files,groups); try Task.checkCancellation(); guard active, loadID == generation else { return }
                datasets = (data["datasets"]?.items ?? []).map(DatasetRecord.init); folders = group["folders"]?.items ?? []; limits = data["limits"] ?? .null; loaded = true; loading = false; selected.formIntersection(datasets.map(\.id))
                if DatasetRequest.id(view) && !folders.contains(where:{$0.text("id")==view}) { view = "home"; tab = "mine" }
                if !poll || !datasets.contains(where:{$0.busy}) { break }; try await Task.sleep(for:.seconds(3))
            } while !Task.isCancelled
        } catch { if active && loadID == generation && !(error is CancellationError) { self.error = explain(error) } }
        if active && loadID == generation && !Task.isCancelled { loading = false }
    }
    private func mutate(_ path:String,_ method:String,_ body:JSONValue? = nil,query:[String:String] = [:]) async { guard !busy else { return }; busy = true; error = nil; do { _ = try await request(path,method,body,query:query); notice = "已保存"; await load() } catch { if !(error is CancellationError) { self.error = explain(error) } }; busy = false; refresh = UUID() }
    private func save(unlink:Bool = false) async {
        guard !busy else { return }; busy = true; sheetError = nil
        do {
            switch action {
            case "createFolder":
                let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines), about = descriptionText.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !trimmed.isEmpty else { sheetError = "项目名称不能为空"; busy = false; return }
                guard !trimmed.contains("/") && !trimmed.contains("\\") else { sheetError = "项目名称不能包含斜杠符号"; busy = false; return }
                var body: [String: JSONValue] = ["name":.string(trimmed)]; if !about.isEmpty { body["description"] = .string(about) }
                _ = try await request("/api/datasets/folders","POST",.object(body)); notice = "项目「\(trimmed)」已创建。"
            case "pick":
                guard DatasetRequest.id(view), !picked.isEmpty else { throw APIError.invalidResponse }
                _ = try await request("/api/datasets/move-batch","POST",.object(["folder_id":.string(view),"dataset_ids":.array(picked.sorted().map(JSONValue.string))]))
                notice = "已移入 \(picked.count) 份资料。"; picked = []
            case "renameFolder": _ = try await request("/api/datasets/folders/" + target.text("id"),"PATCH",.object(["name":.string(name)]))
            case "rename": _ = try await request("/api/datasets/" + target.text("id"),"PATCH",.object(["name":.string(name)]))
            case "move": guard DatasetRequest.id(destination) else { throw APIError.invalidResponse }; _ = try await request("/api/datasets/move-batch","POST",.object(["folder_id":.string(destination),"dataset_ids":.array(selected.sorted().map(JSONValue.string))])); selected = []; notice = "已移动到「\(folders.first { $0.text("id") == destination }?.text("name") ?? "项目")」。"
            case "deleteFolder": _ = try await request("/api/datasets/folders/" + target.text("id"),"DELETE",query:["confirm_contents":"true"])
            case "deleteBatch":
                var failures:[String] = []; var removed = 0
                for item in datasets.filter({selected.contains($0.id)}) { do { _ = try await request("/api/datasets/" + item.id,"DELETE"); selected.remove(item.id); removed += 1 } catch { if error is CancellationError { throw error }; failures.append(item.name + "：" + explain(error)) } }
                notice = "已删除 \(removed) 份资料"; if !failures.isEmpty { throw APIError.server(status:409,code:failures.joined(separator:"；")) }
            case "associate":
                let old = target.text("interview_session_id"), id = target.text("id")
                if !old.isEmpty && (unlink || old != destination) { _ = try await request("/api/interview-sessions/" + old + "/assets/" + id,"DELETE"); target = .object(["id":.string(id),"file_name":target["file_name"] ?? .null]); notice = "旧关联已解除" }
                if !unlink && destination != old { guard DatasetRequest.id(destination) else { throw APIError.invalidResponse }; _ = try await request("/api/interview-sessions/" + destination + "/assets/attach","POST",.object(["dataset_id":.string(id)])) }
            case "uploadRename":
                guard let index = queue.firstIndex(where:{$0.id==queueID}), !name.isEmpty else { throw APIError.invalidResponse }
                let ext = URL(fileURLWithPath:queue[index].upload.name).pathExtension
                queue[index].upload.name = name.lowercased().hasSuffix("." + ext.lowercased()) ? name : name + "." + ext; queue[index].upload = queue[index].upload.rekey(); queue[index].status = "selected"; queue[index].message = "等待重新上传"
            case "replace":
                guard let index = queue.firstIndex(where:{$0.id==queueID}), target.text("asset_kind") == "document" else { throw APIError.invalidResponse }
                queue[index].upload.replacing = target.text("id"); queue[index].upload.revision = target.text("content_revision"); queue[index].upload.name = target.text("file_name"); queue[index].upload = queue[index].upload.rekey(); queue[index].status = "selected"; queue[index].message = "已确认替换，等待上传"
            default: break
            }
            action = nil; await load()
        } catch { if !(error is CancellationError) { sheetError = explain(error); await load() } }
        busy = false; refresh = UUID()
    }
    private func loadSessions() async {
        loading = true; do { var values:[JSONValue] = [], cursor = ""; var seen = Set<String>(); repeat { var query = ["limit":"500"]; if !cursor.isEmpty { query["cursor"] = cursor }; let data = try await request("/api/interview-sessions",query:query); values += data["items"]?.items ?? []; cursor = data.text("next_cursor"); if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse } } while !cursor.isEmpty; sessions = values } catch { if !(error is CancellationError) { sheetError = explain(error) } }; loading = false
    }
    private func open(_ item:DatasetRecord) { guard !busy else { return }; if !item.ready { notice = "\(item.status)，暂时无法预览。"; return }; if item.media { show("media",item.raw); Task { await loadMedia(item) } } else { show("preview",item.raw); Task { await loadPreview() } } }
    private func loadPreview() async { let id = target.text("id"); loading = true; sheetError = nil; do { let data = try await request("/api/datasets/" + id + "/content"); if action == "preview" && target.text("id") == id { preview = data.text("markdown") } } catch { if !(error is CancellationError) { sheetError = explain(error) } }; loading = false }
    private func loadMedia(_ item:DatasetRecord) async {
        let owner = account; loading = true
        do { let file = try await session.api.downloadDataset(id:item.id,limit:maximum); var retained = false; defer { if !retained { file.discard() } }; guard active, owner == account, action == "media", target.text("id") == item.id else { file.discard(); throw CancellationError() }; let playable = file.url.deletingLastPathComponent().appendingPathComponent("preview." + item.format.lowercased()); try FileManager.default.moveItem(at:file.url,to:playable); mediaFile = file; retained = true; player = AVPlayer(url:playable) }
        catch { if active && owner == account && !(error is CancellationError) { sheetError = explain(error) } }
        if active && owner == account { loading = false }
    }
    private func download(_ item:DatasetRecord) async {
        guard !busy else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = item.name; guard panel.runModal() == .OK, let destination = panel.url else { return }
        let owner = account; busy = true; error = nil
        do { let file = try await session.api.downloadDataset(id:item.id,limit:maximum); defer { file.discard() }; guard owner == account && !owner.isEmpty else { throw CancellationError() }; let allowed = destination.startAccessingSecurityScopedResource(); defer { if allowed { destination.stopAccessingSecurityScopedResource() } }; if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:file.url) } else { try FileManager.default.copyItem(at:file.url,to:destination) }; notice = "已保存「\(item.name)」" } catch { if active && owner == account && !(error is CancellationError) { self.error = explain(error) } }; if active && owner == account { busy = false }
    }
    private func pick() { guard !busy, !account.isEmpty, DatasetRequest.id(folder) else { if account.isEmpty { pending = "createFolder"; requireAccount() }; return }; let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; let configured = (limits["allowed_extensions"]?.items ?? []) + (limits["media_allowed_extensions"]?.items ?? []); let extensions = configured.compactMap(\.stringValue); panel.allowedContentTypes = (extensions.isEmpty ? ["pdf","docx","md","txt","webm","m4a","mp3","wav","ogg","mp4","mov"] : extensions).compactMap{UTType(filenameExtension:$0.trimmingCharacters(in:CharacterSet(charactersIn:".")))}; guard panel.runModal() == .OK else { return }; let targetFolder = folder; Task { await enqueue(panel.urls,into:targetFolder) } }
    private func enqueue(_ urls:[URL],into targetFolder:String) async {
        let owner = account; guard !owner.isEmpty else { return }
        let batch = max(1,limits["max_files_per_batch"]?.integer ?? 10)
        for url in urls.prefix(max(0,batch - queue.filter{$0.status != "accepted"}.count)) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { let media = ["webm","m4a","mp3","wav","ogg","mp4","mov"].contains(url.pathExtension.lowercased()); let limit = media ? maximum : min(maximum,Int64(limits["max_file_bytes"]?.numberValue ?? 20*1024*1024)); let upload = try await Task.detached { try DatasetUpload.snapshot(url,folder:targetFolder,limit:limit) }.value; guard active, owner == account, queue.filter({$0.status != "accepted"}).count < batch else { upload.discard(); return }; queue.append(LibraryQueued(upload:upload)) } catch { if active && owner == account { self.error = "\(url.lastPathComponent)：" + explain(error) } }
        }
        if urls.count > batch { notice = "每批最多 \(batch) 个文件，超出部分未加入。" }
    }
    private var uploadQueue: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("上传队列").font(.headline); Spacer(); Button("上传 / 重试") { uploadTask = Task { await uploadAll() } }.buttonStyle(WebActionStyle()).disabled(busy) }
            ForEach(queue) { item in
                HStack { VStack(alignment:.leading,spacing:5) { Text(item.upload.name); Text((folders.first{$0.text("id")==item.upload.folder}?.text("name") ?? "文件夹") + " · " + item.message).font(LibraryTypography.sans(11)).foregroundStyle(item.status == "unknown" ? .orange:.secondary) }; Spacer()
                    if item.status == "conflict" { Button("保留两份") { queueID = item.id; show("uploadRename"); name = item.upload.name }; if let existing = datasets.first(where:{$0.folder==item.upload.folder && $0.name.precomposedStringWithCanonicalMapping==item.upload.name.precomposedStringWithCanonicalMapping}), !existing.media { Button("替换…") { queueID = item.id; show("replace",existing.raw) } } }
                    if item.status != "uploading" { Button(item.status == "accepted" ? "关闭":"移出") { item.upload.discard(); queue.removeAll{$0.id==item.id} } }
                }.disabled(busy)
            }
            Text("目标文件夹已固定。结果不确定时沿用原标识重试；退出账号或离开资料库会清理临时文件。").font(LibraryTypography.sans(11)).foregroundStyle(.secondary)
        }.padding(20).background(Color(hex:0xF7F7F4),in:RoundedRectangle(cornerRadius:14))
    }
    private func uploadAll() async {
        guard !busy else { return }; let owner = account; busy = true; error = nil
        for id in queue.filter({["selected","unknown","rejected"].contains($0.status)}).map(\.id) {
            guard let index = queue.firstIndex(where:{$0.id==id}), owner == account, !Task.isCancelled else { break }
            let upload = queue[index].upload; queue[index].status = "uploading"; queue[index].message = "正在上传…"
            do { _ = try await session.api.uploadDataset(upload); guard active, owner == account else { break }; if let index = queue.firstIndex(where:{$0.id==id}) { queue[index].status = "accepted"; queue[index].message = "服务器已接受"; upload.discard() } }
            catch { guard active, owner == account, let index = queue.firstIndex(where:{$0.id==id}) else { break }; if case APIError.server(let status,let code) = error, (400..<500).contains(status) { queue[index].status = code.contains("CONFLICT") ? "conflict":"rejected"; queue[index].upload = upload.rekey(); queue[index].message = explain(error) } else { queue[index].status = "unknown"; queue[index].message = "结果尚未确认；重试沿用原标识。" } }
        }
        if owner == account { busy = false; await load(); refresh = UUID() }
    }
    /// 求职进程：全部投递（含归档）与面试场次，读失败不影响「我的项目」。
    private func loadJobs(background:Bool = false) async {
        guard !account.isEmpty else { return }
        if !background { jobState = "loading" }
        do {
            async let apps = pages("/api/job-applications",["scope":"all","limit":"200"])
            async let rounds = pages("/api/interview-sessions",["include_archived":"true","limit":"500"])
            let (a,r) = try await (apps,rounds)
            applications = a; jobSessions = r; jobState = "ready"
        } catch { if !(error is CancellationError) && !background { jobState = "failed" } }
    }
    private func pages(_ path:String,_ base:[String:String]) async throws -> [JSONValue] {
        var values:[JSONValue] = [], cursor = "", seen = Set<String>()
        repeat {
            var query = base; if !cursor.isEmpty { query["cursor"] = cursor }
            let page = try await request(path,query:query); values += page["items"]?.items ?? []; cursor = page.text("next_cursor")
            if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse }
        } while !cursor.isEmpty
        return values
    }
    /// `StorageUsage`：资料与音视频空间来自额度摘要（对话附件和模拟面试录音也算在内）。
    private func loadStorage() async {
        guard !account.isEmpty, let summary = try? await request("/api/billing/summary") else { return }
        storage = summary["storage"]
    }
    private func saveDescription() async {
        guard let draft, let current = currentFolder, !savingDescription else { return }
        let next = draft.trimmingCharacters(in:.whitespacesAndNewlines)
        if next == current.text("description") { self.draft = nil; return }
        savingDescription = true
        do {
            let updated = try await request("/api/datasets/folders/" + current.text("id"),"PATCH",.object(["description":.string(next)]))
            folders = folders.map { item in
                guard item.text("id") == current.text("id"), case .object(var fields) = item else { return item }
                fields["description"] = updated["description"].flatMap { $0 == .null ? nil : $0 } ?? .string(next); return .object(fields)
            }
            self.draft = nil; notice = "项目说明已保存。"
        } catch {
            if !(error is CancellationError) { if case APIError.server(_,let code) = error, code == "INVALID_FOLDER_DESCRIPTION" { self.error = "项目说明最多 500 字，且不能包含特殊控制字符" } else { self.error = explain(error) } }
        }
        savingDescription = false
    }
    private func pickList<Content:View>(height:CGFloat? = nil,maxHeight:CGFloat? = nil,@ViewBuilder _ content:() -> Content) -> some View {
        ScrollView { VStack(spacing:height == nil ? 6 : 8) { content() }.padding(.horizontal,6).padding(.vertical,height == nil ? 7 : 8) }
            .frame(height:height).frame(maxHeight:maxHeight).fixedSize(horizontal:false,vertical:height == nil)
            .overlay(RoundedRectangle(cornerRadius:12).stroke(V3.cl))
    }
    private func pickRow<Content:View>(checked:Bool,height:CGFloat = 38,action:@escaping () -> Void,@ViewBuilder _ content:() -> Content) -> some View {
        Button(action:action) {
            HStack(spacing:10) { content() }.font(V3.sans(13,weight:checked ? .medium : .regular)).foregroundStyle(checked ? V3.txt : V3.sub)
                .padding(.horizontal,10).frame(minHeight:height).frame(maxWidth:.infinity,alignment:.leading)
                .background(checked ? V3.hl : .clear,in:RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy).accessibilityAddTraits(checked ? .isSelected : [])
    }
    /// `AssociateArt`：资料卡 —— 虚线与链接圆点 —— 面试卡（240×96 居中）。
    private var associateArt: some View {
        let tone = formatTone(DatasetRecord(target))
        func card(_ head: some View) -> some View {
            ZStack(alignment:.topLeading) {
                RoundedRectangle(cornerRadius:8).fill(.white).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.cl)).shadow(color:.black.opacity(0.06),radius:8,y:6)
                head.frame(width:24,height:24).offset(x:10,y:10)
                RoundedRectangle(cornerRadius:2).fill(V3.sk2).frame(width:26,height:4).offset(x:40,y:14)
                RoundedRectangle(cornerRadius:2).fill(V3.line).frame(width:20,height:4).offset(x:40,y:24)
                RoundedRectangle(cornerRadius:2).fill(V3.line).frame(width:56,height:3).offset(x:10,y:40)
            }.frame(width:76,height:52,alignment:.topLeading)
        }
        return ZStack(alignment:.topLeading) {
            card(Text(tone.label).font(V3.number(7,weight:.bold)).foregroundStyle(tone.color).frame(width:24,height:24).background(tone.tint,in:RoundedRectangle(cornerRadius:6))).offset(y:22)
            Path { $0.move(to:CGPoint(x:82,y:48)); $0.addLine(to:CGPoint(x:158,y:48)) }.stroke(Color(hex:0xB9B9B3),style:StrokeStyle(lineWidth:1.4,dash:[3,3]))
            Image(systemName:"link").font(.system(size:11)).foregroundStyle(V3.sub).frame(width:24,height:24).background(.white,in:Circle()).overlay(Circle().stroke(V3.cl)).offset(x:108,y:36)
            card(CareerIcon(name:"calendar",size:14,template:true).foregroundStyle(V3.blue).frame(width:24,height:24).background(Color(hex:0xEEF3FC),in:RoundedRectangle(cornerRadius:6))).offset(x:164,y:22)
        }.frame(width:240,height:96,alignment:.topLeading).accessibilityHidden(true)
    }
    /// 面试场次副标题：「三面 · 09-27 周日 16:00 · 飞书视频」；已完成 / 已取消的写状态。
    private func sessionMeta(_ item:JSONValue) -> String {
        let when = CareerApplication.date(item.text("start_at")).map { date in
            let c = Calendar.current.dateComponents([.month,.day,.weekday,.hour,.minute],from:date)
            return String(format:"%02d-%02d 周%@ %02d:%02d",c.month ?? 0,c.day ?? 0,["日","一","二","三","四","五","六"][(c.weekday ?? 1) - 1],c.hour ?? 0,c.minute ?? 0)
        } ?? ""
        let tail = item.text("status") == "completed" ? "已完成" : item.text("status") == "cancelled" ? "已取消" : item.text("location").nonEmptyValue ?? ["video":"视频面试","onsite":"现场","phone":"电话","other":"其他"][item.text("mode")] ?? ""
        return [item.text("stage_label"),when,tail].filter { !$0.isEmpty }.joined(separator:" · ")
    }
    /// `.ds-preview-meta`：格式 · 大小 · 上传于 · 已关联 · 管理关联。
    private var previewMeta: some View {
        HStack(spacing:10) {
            Text("\(target.text("file_format").uppercased()) · \(JobProjects.size(target["file_size"]?.numberValue ?? 0)) · 上传于 \(date(target.text("created_at")))").font(V3.number(12,weight:.regular))
            if !target.text("interview_label").isEmpty || target.text("upload_status") == "succeeded" { Text("·").foregroundStyle(V3.fnt2) }
            if !target.text("interview_label").isEmpty { HStack(spacing:5) { CareerIcon(name:"calendar",size:13,template:true); Text("已关联：面试 · " + target.text("interview_label")) }.foregroundStyle(V3.sub) }
            if target.text("upload_status") == "succeeded" { Button("管理关联") { let item = target; show("associate",item); Task { await loadSessions() } }.buttonStyle(.plain).foregroundStyle(V3.txt) }
        }.font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height:14).padding(.top,8)
    }
    /// 音频：播放器 + 还没有文字稿时的转写状态（桌面端暂不开放发起转写，转写在 Web 或求职进度里完成）；视频：播放器。
    @ViewBuilder private var mediaPreview: some View {
        VStack(alignment:.leading,spacing:12) {
            if let player { VideoPlayer(player:player).frame(height:target.text("asset_kind") == "audio" ? 80 : 380) }
            else if loading { Text("正在读取音频…").font(V3.sans(14)).foregroundStyle(V3.sub) }
            else { Text(sheetError ?? "媒体不可用，请下载原文件重试。").font(V3.sans(14)).foregroundStyle(V3.sub) }
            Button("下载文件") { Task { await download(DatasetRecord(target)) } }.buttonStyle(V3ButtonStyle(kind:.ghost)).disabled(busy)
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.line)).padding(.top,4)
        if target.text("asset_kind") == "audio" && target["has_transcript"]?.bool != true {
            VStack(alignment:.leading,spacing:12) {
                Text("音频转文字").font(V3.sans(16,weight:.semibold)).foregroundStyle(V3.txt)
                Text(transcriptionText).font(V3.sans(14)).foregroundStyle(V3.sub)
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.line))
        }
    }
    private var transcriptionText: String {
        switch target.text("parse_status") {
        case "queued": return "等待转写"
        case "processing": return "正在转写…"
        case "failed": return ["service_unavailable":"语音识别服务未配置或暂不可用，请检查模型设置后重试。","content_invalid":"未识别到有效语音，请检查音频后重试。","size_exceeded":"音频超过语音服务大小限制；AIHubMix 单次转写最多支持 25 MB。"][target.text("failure_reason")] ?? "转写失败，请稍后重试。"
        default: return "这份音频还没有文字稿，可以在网页版资料库开始转写。"
        }
    }
    /// 页面顶部浮动提示，3 秒后消失。
    private func toast(_ text:String) -> some View {
        HStack(spacing:10) {
            Text(text).font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt)
            Button { notice = nil } label:{ Image(systemName:"xmark").font(.system(size:10)) }.buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("关闭提示")
        }
        .padding(.horizontal,16).frame(height:40).background(.white,in:Capsule()).overlay(Capsule().stroke(V3.cl)).shadow(color:.black.opacity(0.08),radius:12,y:4)
        .padding(.top,20).task(id:text) { try? await Task.sleep(for:.seconds(3)); if notice == text { notice = nil } }
    }
    private func date(_ value:String,format pattern:String = "yyyy-MM-dd") -> String { guard let date = CareerApplication.date(value) else { return "—" }; let format = DateFormatter(); format.dateFormat = pattern; return format.string(from:date) }
    private func explain(_ error:Error) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。" }
        if case APIError.server(_,let code) = error { return ["FOLDER_NAME_CONFLICT":"文件夹名称已存在。", "DATASET_NAME_CONFLICT":"同一文件夹已有同名文件，请选择保留两份或确认替换。", "DATASET_FILENAME_CONFLICT":"同一文件夹已有同名文件，请选择保留两份或确认替换。", "DATASET_IN_PROGRESS":"资料正在处理，暂时不能删除或替换。", "DATASET_NOT_RETRYABLE":"只有解析失败的文档可重新解析。", "DATASET_FILE_TOO_LARGE":"文件超出上传限制。", "INVALID_DATASET_NAME":"名称无效，请去除路径符号或控制字符。", "DATASET_ALREADY_LINKED":"已关联其他面试，请刷新后重试。", "FOLDER_NOT_FOUND":"文件夹已不存在，请刷新后选择。", "DATASET_NOT_FOUND":"资料已不存在或不可访问。", "ASSET_DELETE_FAILED":"原文件清理失败，请刷新确认后重试。", "DATASET_BUSY":"资料正在处理，暂时不能删除或替换。", "FOLDER_NAME_DUPLICATE":"文件夹名称已存在。", "DATASET_CONTENT_CONFLICT":"资料已更新，请刷新后重新确认替换。", "PRECONDITION_FAILED":"资料已更新，请刷新后重新确认替换。"][code] ?? "操作未完成（\(code)）。请刷新确认状态后再试。" }
        return "连接失败，结果尚未确认。请刷新或沿用原标识重试。"
    }
}

/// `.ds-blank-chip`：空状态里的轻量胶囊按钮。
private struct ChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(V3.sans(13)).foregroundStyle(V3.txt).padding(.horizontal,14).frame(height:32)
            .background(configuration.isPressed ? Color(hex:0xFBFBFA) : .white,in:Capsule()).overlay(Capsule().stroke(V3.cl))
            .opacity(enabled ? 1 : 0.5).contentShape(Capsule())
    }
}

private struct LibraryCreateButtonStyle: ButtonStyle {
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(LibraryTypography.sans(12,weight:.medium)).foregroundStyle(.white)
            .frame(width:120,height:32).background(Color(hex:0x1D1D1B).opacity(configuration.isPressed ? 0.8:1),in:RoundedRectangle(cornerRadius:7))
    }
}

enum LibraryTypography {
    static let registered: Void = {
        for (name,ext) in [("LibrarySans-Regular","otf"),("LibrarySerif-SemiBold","ttf")] {
            if let url = Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Library") {
                CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
            }
        }
    }()
    static func sans(_ size:CGFloat,weight:Font.Weight = .regular) -> Font {
        _ = registered
        return .custom("DrawOfferLibrarySans-Regular",size:size).weight(weight)
    }
    static func serif(_ size:CGFloat) -> Font {
        _ = registered
        return .custom("DrawOfferLibrarySerif-SemiBold",size:size)
    }
}

private struct LibraryIcon: View {
    let name:String
    let size:CGFloat
    var body:some View {
        if let url = Bundle.module.url(forResource:name,withExtension:"png",subdirectory:"Library"), let image = NSImage(contentsOf:url) {
            Image(nsImage:image).resizable().frame(width:size,height:size).accessibilityHidden(true)
        }
    }
}
