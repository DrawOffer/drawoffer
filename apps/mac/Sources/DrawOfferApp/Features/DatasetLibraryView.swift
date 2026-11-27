import AppKit
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
    /// 别处要打开某一份资料（`WorkspaceRouter.Jump.dataset`）：进资料预览页后清空。
    var openDataset: Binding<String?> = .constant(nil)
    @State private var datasets: [DatasetRecord] = []
    @State private var folders: [JSONValue] = []
    @State private var limits: JSONValue = .null
    /// "home" / "files" / 项目 id / "app:<投递 id>"（求职进程项目）/ "ds:<资料 id>"（资料预览页）。
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
    @State private var notice: NoticeToastItem?
    @State private var refresh = UUID()
    @State private var action: String?
    @State private var target: JSONValue = .null
    @State private var name = ""
    @State private var destination = ""
    @State private var sessions: [JSONValue] = []
    @State private var sheetError: String?
    @State private var queue: [LibraryQueued] = []
    @State private var queueID: UUID?
    @State private var active = true
    @State private var loadID = UUID()
    @State private var uploadTask: Task<Void,Never>?
    @State private var batchMode = false
    @State private var hoveredRow: String?
    /// 上传弹窗里已选、还没开始上传的文件（02.01）。
    @State private var staged: [LibraryQueued] = []
    /// 正在询问「替换 / 保留两份」的同名上传（02.02）。
    @State private var conflictID: UUID?
    @State private var sortKey = "recent"
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

    /// 资料库（macOS 稿 10 页 + 17.01 新外壳）：首页是 05「我的项目 / 求职进程」两个标签（Web 现行项目化版本）；
    /// 项目详情与「全部文件」沿用 Web 现行的列表页（10 页 01.02 / 04.01 版式）。页头固定，正文单独滚动。
    var body: some View {
        GeometryReader { geometry in
            let card = geometry.size.width, gutter = V3Page<EmptyView>.gutter(card: card)
            let width = min(V3Page<EmptyView>.maxWidth(card: card), max(0, card - gutter * 2))
            Group {
                if view.hasPrefix("app:") { jobProject(String(view.dropFirst(4))) }
                else if view.hasPrefix("ds:") { viewer(String(view.dropFirst(3))) }
                else {
                    VStack(alignment:.leading,spacing:0) {
                        header(width:width).padding(.horizontal,gutter)
                        ScrollView {
                            VStack(alignment:.leading,spacing:0) {
                                if loading && !loaded { if view == "home" { homeSkeleton } else { listSkeleton } }
                                else if !account.isEmpty && !loaded { loadFailed }
                                else if view == "home" { home }
                                else { fileList }
                                if let error {
                                    HStack(spacing:10) { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red); Spacer(); Button("重新刷新") { refresh = UUID() }.buttonStyle(CareerActionStyle(kind:.link)).disabled(busy) }.padding(.top,16)
                                }
                            }.frame(width:width,alignment:.topLeading).padding(.horizontal,gutter).padding(.bottom,48)
                        }
                    }
                }
            }
        }
        .overlay(alignment:.bottom) { if batchMode && view != "home" { batchBar } }
        .overlay(alignment:.top) { NoticeToast(item:$notice).padding(.top,20) }
        .task(id:account + refresh.uuidString) { active = true; await load(poll:true) }
        .task(id:account + refresh.uuidString + "jobs") { await loadJobs() }
        .task(id:account + "storage" + "\(datasets.count):\(datasets.reduce(0) { $0 + ($1.raw["file_size"]?.numberValue ?? 0) })") { await loadStorage() }
            .onChange(of:account) { _, id in
                uploadTask?.cancel(); queue.forEach { $0.upload.discard() }; queue = []; action = nil; selected = []; datasets = []; folders = []; loaded = false; limits = .null; error = nil; sheetError = nil; notice = nil; busy = false; view = "home"; tab = "mine"; query = ""; sessions = []; applications = []; jobSessions = []; jobState = "loading"; storage = nil; draft = nil
                batchMode = false; conflictID = nil
            }
            .onChange(of:openDataset.wrappedValue,initial:true) { _, id in if let id, DatasetRequest.id(id) { view = "ds:" + id; openDataset.wrappedValue = nil } }
            .onChange(of:view) { draft = nil; addMenu = false }
            .onDisappear { active = false; loadID = UUID(); uploadTask?.cancel(); queue.forEach { $0.upload.discard() } }
            .centeredSheet(isPresented:Binding(get:{action != nil},set:{if !$0 && !busy { if action == "upload" { discardStaged() }; action = nil }})) { sheet }
            .centeredAlert("项目里已有同名文件",isPresented:Binding(get:{conflictID != nil && action == nil},set:{ if !$0 { conflictID = nil } })) { conflictActions } message: { Text(conflictMessage) }
            .onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
                guard !busy, DatasetRequest.id(view), !account.isEmpty else { return false }
                let targetFolder = view, owner = account
                for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in guard owner == account else { return }; await enqueue([url],into:targetFolder); startUpload() } } } }
                return true
            }
    }
    private var folder: String { DatasetRequest.id(view) ? view : "" }
    private var currentFolder: JSONValue? { folders.first { $0.text("id") == view } }
    private var folderName: String { currentFolder?.text("name") ?? "当前项目" }
    private var listedProjects: [JobProjects.Project] { jobProjects.filter { $0.datasetCount > 0 || $0.recordCount > 0 } }
    private var projectCount: Int { folders.count + listedProjects.count }

    /// 页头。首页（05.01）：30 号衬线「资料库」+ 13 灰字统计（项目 · 资料 · 存储用量），右侧搜索 / 全部文件 / 唯一黑按钮「新建项目」与统计行底对齐；
    /// 下面一行是两个文字标签（选中 13.5 中粗墨黑，未选灰色，后跟数量）和右侧「最近活动 ⌄」排序。
    /// 项目详情 / 全部文件（04.01）：11.5 面包屑 → 28 号衬线标题 → 13 灰字摘要 → 项目说明，最后一条分隔线。
    private func header(width:CGFloat) -> some View {
        VStack(alignment:.leading,spacing:0) {
            if view == "home" {
                HStack(alignment:.bottom,spacing:16) {
                    VStack(alignment:.leading,spacing:0) {
                        Text("资料库").font(V3.serif(30)).foregroundStyle(V3.txt).frame(height:43)
                        Group {
                            if loaded { Text(homeSummary) } else { V3Skeleton(width:124,height:8,radius:4).frame(height:16) }
                        }.font(V3.sans(13)).foregroundStyle(LibraryTone.faint).lineLimit(1).frame(height:16).padding(.top,4)
                    }
                    Spacer(minLength:0)
                    headerActions
                }
                HStack(alignment:.center,spacing:22) {
                    tabButton("mine","我的项目",loaded ? "\(folders.count)" : "")
                    tabButton("jobs","求职进程",jobState == "ready" ? "\(listedProjects.count)" : "")
                    Spacer(minLength:0)
                    if loaded, let storageSummary { Text(storageSummary).font(V3.sans(12)).foregroundStyle(LibraryTone.faint).lineLimit(1) }
                    if loaded && tab == "mine" && !folders.isEmpty { sortMenu }
                }.frame(height:20).padding(.top,30).padding(.bottom,17)
            } else {
                HStack(spacing:8) {
                    Button { go("home") } label:{ HStack(spacing:5) { Image(systemName:"chevron.left").font(.system(size:9,weight:.semibold)); Text("资料库").font(V3.sans(11.5,weight:.medium)) }.foregroundStyle(V3.sub).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("返回资料库").disabled(busy)
                    Text("/").font(V3.sans(11.5)).foregroundStyle(V3.fnt2).accessibilityHidden(true)
                    Text(view == "files" ? "全部文件" : folderName).font(V3.sans(11.5)).foregroundStyle(LibraryTone.faint).lineLimit(1)
                }.frame(height:14).padding(.top,4)
                HStack(alignment:.top,spacing:16) {
                    VStack(alignment:.leading,spacing:0) {
                        Text(view == "files" ? "全部文件" : folderName).font(V3.serif(28)).foregroundStyle(V3.txt).lineLimit(1).frame(height:40)
                        Group { if loaded { Text(folderSubtitle) } else { V3Skeleton(width:160,height:8).frame(height:16) } }
                            .font(V3.sans(13)).foregroundStyle(V3.sub).lineLimit(1).frame(height:16).padding(.top,2)
                    }
                    Spacer(minLength:0)
                    headerActions.padding(.top,6)
                }.padding(.top,20)
                if view != "files", let currentFolder, loaded { description(currentFolder).padding(.top,14) }
                Rectangle().fill(V3.line).frame(height:1).padding(.top,24)
            }
        }
        .frame(width:width,alignment:.leading)
        .padding(.top,view == "home" ? 68 : 52)
    }
    private var homeSummary: String {
        "\(projectCount) 个项目 · \(datasets.count) 份资料"
    }
    /// 存储用量放到标签栏右端（Web `DatasetsPage`：「存储用量放到标签栏右端」；Figma 05.01 摘要只写项目与资料数）。
    private var storageSummary: String? {
        guard let storage else { return nil }
        return "资料 \(JobProjects.size(storage["datasetBytesUsed"]?.numberValue ?? 0)) / \(JobProjects.size(storage["datasetBytesLimit"]?.numberValue ?? 0))"
            + " · 音视频 \(JobProjects.size(storage["mediaBytesUsed"]?.numberValue ?? 0)) / \(JobProjects.size(storage["mediaBytesLimit"]?.numberValue ?? 0))"
    }
    private func tabButton(_ id:String,_ label:String,_ count:String) -> some View {
        Button { tab = id; query = "" } label:{
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text(label).font(V3.sans(13.5,weight:tab == id ? .medium : .regular)).foregroundStyle(tab == id ? V3.txt : LibraryTone.faint)
                if !count.isEmpty { Text(count).font(V3.number(12,weight:.regular)).foregroundStyle(tab == id ? V3.sub : LibraryTone.faint) }
            }.frame(height:20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(tab == id ? .isSelected : [])
    }
    /// 「最近活动 ⌄」：我的项目按最近活动 / 名称 / 资料数排序。
    private var sortMenu: some View {
        Menu {
            ForEach([("recent","最近活动"),("name","名称"),("count","资料数量")],id:\.0) { key,label in
                Button { sortKey = key } label:{ if sortKey == key { Label(label,systemImage:"checkmark") } else { Text(label) } }
            }
        } label:{
            HStack(spacing:4) { Text(sortLabel).font(V3.sans(12.5)).foregroundStyle(V3.sub); Image(systemName:"chevron.down").font(.system(size:8,weight:.medium)).foregroundStyle(LibraryTone.faint) }
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("排序方式：\(sortLabel)")
    }
    private var sortLabel: String { ["name":"名称","count":"资料数量"][sortKey] ?? "最近活动" }
    @ViewBuilder private var headerActions: some View {
        HStack(spacing:9) {
            if view == "home" {
                LibrarySearchField(text:$query,placeholder:"搜索项目或文件",width:200,height:34)
                Button("全部文件") { go("files") }.buttonStyle(V3ButtonStyle(kind:.ghost,height:36)).disabled(batchMode)
                Button("新建项目") { show("createFolder") }.buttonStyle(V3ButtonStyle(kind:.dark,height:36)).disabled(busy || batchMode)
            } else {
                LibrarySearchField(text:$query,placeholder:"搜索资料…",width:180,height:32).padding(.trailing,2)
                Button(batchMode ? "取消操作" : "批量操作") { batchMode.toggle(); selected = [] }.buttonStyle(V3ButtonStyle(kind:.ghost,width:91)).disabled(busy)
                if DatasetRequest.id(view) {
                    Button { addMenu = true } label:{ Image(systemName:"plus").font(.system(size:11,weight:.medium)); Text("添加资料") }
                        .buttonStyle(V3ButtonStyle(kind:.dark,width:108)).disabled(busy || batchMode || !loaded)
                        .popover(isPresented:$addMenu,arrowEdge:.bottom) { addMenuContent }
                }
            }
        }
    }
    /// 添加资料菜单（05.03）：每项一行标题 + 一行灰字说明。
    private var addMenuContent: some View {
        VStack(spacing:2) {
            LibraryMenuItem(icon:"plus",title:"上传本地文件",detail:"PDF、Word、Markdown、音视频") { addMenu = false; show("upload") }
            LibraryMenuItem(icon:"folder",title:"从资料库选择",detail:"从其他项目挑几份移进来") { addMenu = false; openPicker() }
        }.padding(6).frame(width:240)
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
    private func listDate(_ value:String) -> String {
        guard let date = CareerApplication.date(value) else { return value }
        return self.date(value,format:Beijing.calendar.component(.year,from:date) == Beijing.calendar.component(.year,from:Date()) ? "MM-dd" : "yyyy-MM-dd")
    }
    /// 首页正文：我的项目网格（05.01，卡片 272×189、横向间距 20、行距 24）或求职进程卡片（05.02，272×131）；
    /// 没有项目时是 06 的居中空状态（不再放孤零零的虚线「新建项目」卡）。
    @ViewBuilder private var home: some View {
        let keyword = query.trimmingCharacters(in:.whitespaces).lowercased()
        if tab == "mine" {
            let shown = sortedFolders.filter { keyword.isEmpty || $0.text("name").lowercased().contains(keyword) }
            if !keyword.isEmpty && shown.isEmpty { noMatch("没有匹配的项目。") }
            else if folders.isEmpty {
                blank(title:"还没有自己的项目",lines:["按一件事把资料放在一起，比如一次秋招、一门复习或一套证书。","在求职进度里上传的录音和笔记，会自动归到「求职进程」。"]) {
                    Text("从常用的开始").font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.trailing,1)
                    ForEach(["秋招简历打磨","面试题库","证书与成绩单"],id:\.self) { item in Button(item) { show("createFolder"); name = item }.buttonStyle(ChipStyle()).disabled(batchMode) }
                }
            } else {
                grid { ForEach(shown,id:\.self) { folderCard($0) } }
            }
        } else if jobState == "loading" {
            grid { ForEach(0..<3,id:\.self) { _ in jobCardSkeleton } }
        } else if jobState == "failed" {
            V3LoadFailed(message:"求职进程没有加载出来。") { Task { await loadJobs() } }.padding(.top,8)
        } else if listedProjects.isEmpty {
            blank(title:"还没有放了资料的求职进程",lines:["在求职进度里给某一轮上传录音、笔记或文件后，","这条投递会出现在这里，按轮次整理好。"],audio:true) {
                Button("打开投递看板") { router?.jump(.section(.jobs)) }.buttonStyle(ChipStyle())
            }
        } else {
            let shown = listedProjects.filter { keyword.isEmpty || $0.name.lowercased().contains(keyword) }
            if shown.isEmpty { noMatch("没有匹配的项目。") } else { grid { ForEach(shown) { jobCard($0) } } }
        }
    }
    private func noMatch(_ text:String) -> some View { Text(text).font(V3.sans(13)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).padding(.vertical,40) }
    private func grid<Content:View>(@ViewBuilder _ content:() -> Content) -> some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:262),spacing:20,alignment:.top)],alignment:.leading,spacing:24) { content() }
    }
    private var sortedFolders: [JSONValue] {
        func stamp(_ folder:JSONValue) -> Double {
            max(JobProjects.time(folder.text("updated_at")), datasets.filter { $0.folder == folder.text("id") }.map { JobProjects.time($0.raw.text("created_at")) }.max() ?? 0)
        }
        func count(_ folder:JSONValue) -> Int { folder["dataset_count"]?.integer ?? datasets.filter { $0.folder == folder.text("id") }.count }
        switch sortKey {
        case "name": return folders.sorted { $0.text("name").localizedStandardCompare($1.text("name")) == .orderedAscending }
        case "count": return folders.sorted { count($0) == count($1) ? stamp($0) > stamp($1) : count($0) > count($1) }
        default: return folders.sorted { stamp($0) > stamp($1) }
        }
    }
    private func recent(_ folder:String) -> [DatasetRecord] { datasets.filter { $0.folder == folder }.sorted { $0.raw.text("created_at") > $1.raw.text("created_at") } }
    /// 项目卡（05.01）：白底 13.5 圆角、1px #ECECEA 描边、无阴影；内缩 8 的 118 高浅灰舞台（圆角 10）里排 1–3 张纸，
    /// 下面 14 中粗名称 + 12 灰字「N 份资料」，名称行右侧 ⋯ 菜单。
    private func folderCard(_ item:JSONValue) -> some View {
        let records = recent(item.text("id"))
        let count = item["dataset_count"]?.integer ?? records.count
        return Button { go(item.text("id")) } label:{
            VStack(alignment:.leading,spacing:0) {
                folderStage(count == 0 ? [] : Array(records.prefix(3))).frame(maxWidth:.infinity).frame(height:118)
                    .background(LibraryTone.stage,in:RoundedRectangle(cornerRadius:10)).clipShape(RoundedRectangle(cornerRadius:10))
                Text(item.text("name")).font(V3.sans(14,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height:17).padding(.trailing,30).padding(.top,12).padding(.horizontal,6)
                Text(count == 0 ? "还没有资料" : "\(count) 份资料").font(V3.sans(12)).foregroundStyle(LibraryTone.faint).lineLimit(1).frame(height:14).padding(.top,5).padding(.horizontal,6)
            }
            .padding(8).padding(.bottom,7).frame(maxWidth:.infinity,alignment:.leading).frame(height:189,alignment:.top)
            .background(.white,in:RoundedRectangle(cornerRadius:13.5)).overlay(RoundedRectangle(cornerRadius:13.5).stroke(V3.line))
            .contentShape(RoundedRectangle(cornerRadius:13.5))
        }.buttonStyle(.plain).accessibilityLabel("打开项目「\(item.text("name"))」").overlay(alignment:.topTrailing) {
            Menu { Button("重命名") { show("renameFolder",item) }; Divider(); Button("删除项目及资料",role:.destructive) { show("deleteFolder",item) } } label:{
                Image(systemName:"ellipsis").font(.system(size:12,weight:.medium)).foregroundStyle(LibraryTone.faint).frame(width:24,height:20)
            }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().padding(.trailing,12).padding(.top,136).disabled(busy)
                .accessibilityLabel("项目「\(item.text("name"))」操作菜单")
        }
    }
    /// 舞台里的纸：3 张左右各偏 56、两侧轻转 ±3°；2 张左右各偏 28；空项目两张淡纸。
    private func folderStage(_ samples:[DatasetRecord]) -> some View {
        ZStack {
            switch samples.count {
            case 0: ForEach(0..<2,id:\.self) { index in folderSheet(nil).rotationEffect(.degrees(index == 0 ? -2 : 2)).offset(x:index == 0 ? -28 : 28,y:index == 0 ? 4 : 0) }
            case 1: folderSheet(samples[0]).offset(y:4)
            case 2: ForEach(0..<2,id:\.self) { index in folderSheet(samples[index]).rotationEffect(.degrees(index == 0 ? -3 : 3)).offset(x:index == 0 ? -28 : 28,y:index == 0 ? 6 : 2) }
            default: ForEach(0..<3,id:\.self) { index in folderSheet(samples[index]).rotationEffect(.degrees(Double(index - 1) * 3)).offset(x:CGFloat(index - 1) * 56,y:[8,0,6][index]) }
            }
        }.offset(y:8).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    /// 纸张 64×82：墨黑标题条 28×3 + 五行 2px 灰条 + 左下格式色块（24×12、6.5 号白字）；没有资料时是淡色空纸。
    private func folderSheet(_ item:DatasetRecord?) -> some View {
        let ghost = item == nil
        return ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:5).fill(ghost ? Color.white.opacity(0.7) : .white)
                .overlay(RoundedRectangle(cornerRadius:5).stroke(Color(hex:0xE3E3DF).opacity(ghost ? 0.35 : 0.5),lineWidth:0.5))
                .shadow(color:.black.opacity(ghost ? 0.03 : 0.08),radius:4,y:2)
            RoundedRectangle(cornerRadius:1.5).fill(ghost ? V3.txt.opacity(0.12) : V3.txt).frame(width:28,height:3).offset(x:10,y:10)
            ForEach(Array([46,40,46,34,42].enumerated()),id:\.offset) { index,w in RoundedRectangle(cornerRadius:1).fill(Color(hex:0xE3E3DF).opacity(ghost ? 0.5 : 1)).frame(width:CGFloat(w),height:2).offset(x:9,y:CGFloat(20 + index * 6)) }
            if let item {
                let tone = formatTone(item)
                Text(tone.label).font(V3.number(6.5,weight:.medium)).foregroundStyle(.white).padding(.horizontal,4).frame(minWidth:24).frame(height:12).background(tone.color,in:RoundedRectangle(cornerRadius:3)).offset(x:17,y:58)
            }
        }.frame(width:64,height:82,alignment:.topLeading)
    }
    /// 求职进程卡（05.02）：272×131、圆角 13.5、#E8E8E4 描边；32 方字头 + 公司 / 岗位 → 文字阶段链 → 下一场或状态与资料数；只有 Offer 用蓝色。
    private func jobCard(_ project:JobProjects.Project) -> some View {
        let company = project.application.text("company_name_snapshot").trimmingCharacters(in:.whitespaces)
        let role = project.application.text("job_title_snapshot").trimmingCharacters(in:.whitespaces)
        let next = project.next
        let nextDate = next?.date.flatMap(CareerApplication.date).map { String(format:"%02d-%02d",Beijing.calendar.component(.month,from:$0),Beijing.calendar.component(.day,from:$0)) } ?? ""
        return Button { go("app:" + project.id) } label:{
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:10) {
                    Text(project.monogram).font(V3.serif(14)).foregroundStyle(LibraryTone.muted).frame(width:32,height:32).background(LibraryTone.stage,in:RoundedRectangle(cornerRadius:8))
                    VStack(alignment:.leading,spacing:4) {
                        Text(company.isEmpty ? project.name : company).font(V3.sans(14,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height:17)
                        if !company.isEmpty && !role.isEmpty { Text(role).font(V3.sans(12)).foregroundStyle(LibraryTone.muted).lineLimit(1).frame(height:14) }
                    }
                }.frame(height:39)
                HStack(alignment:.firstTextBaseline,spacing:0) {
                    ForEach(Array(project.chain.enumerated()),id:\.offset) { index,node in
                        if index > 0 { Text("›").font(V3.number(11,weight:.regular)).foregroundStyle(LibraryTone.faint).padding(.horizontal,5) }
                        if let node {
                            let focus = node.key == project.focusKey
                            Text(node.label).font(V3.sans(12,weight:focus || node.state == .offer ? .medium : .regular))
                                .foregroundStyle(node.state == .offer ? V3.blue : focus ? V3.txt : node.state == .upcoming ? LibraryTone.faint : LibraryTone.muted)
                        } else { Text("…").font(V3.sans(12)).foregroundStyle(LibraryTone.muted) }
                    }
                }.lineLimit(1).frame(height:17).padding(.top,14)
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    if let next { Text(nextDate.isEmpty ? "下一场 \(next.label)" : "下一场 \(nextDate) \(next.label)").foregroundStyle(LibraryTone.muted).lineLimit(1) }
                    else { Text(project.statusLabel).foregroundStyle(project.offer ? V3.blue : LibraryTone.muted).lineLimit(1) }
                    Spacer(minLength:0)
                    Text(project.materialSummary).foregroundStyle(LibraryTone.faint)
                }.font(V3.sans(11.5)).frame(height:16).padding(.top,14)
            }
            .padding(16).frame(maxWidth:.infinity,alignment:.leading).frame(height:131,alignment:.top)
            .background(project.archived ? Color(hex:0xFBFBFA) : .white,in:RoundedRectangle(cornerRadius:13.5)).overlay(RoundedRectangle(cornerRadius:13.5).stroke(Color(hex:0xE8E8E4)))
            .opacity(project.archived ? 0.6 : 1).contentShape(RoundedRectangle(cornerRadius:13.5))
        }.buttonStyle(.plain).accessibilityLabel("打开求职进程项目「\(project.name)」")
    }
    /// 求职进程项目：和求职进度里的「资料」同一页，左上回资料库，右上多一个「打开求职进度 ↗」。
    @ViewBuilder private func jobProject(_ id:String) -> some View {
        if let project = jobProjects.first(where:{ $0.id == id }) {
            CareerApplicationDetailView(application:CareerApplication(project.application),api:session.api,back:{ view = "home"; tab = "jobs"; Task { await loadJobs(background:true) } },
                                        perform:{ _,app in router?.jump(.application(app.id)) },libraryMaterials:true,openDataset:{ go("ds:" + $0) }).id(id)
        } else if jobState == "loading" {
            V3Loading("正在加载项目…").frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            VStack(spacing:16) {
                Text(jobState == "failed" ? "求职进程加载失败" : "这个求职进程不存在或已删除").font(V3.sans(17,weight:.medium)).foregroundStyle(V3.txt)
                Button("返回资料库") { view = "home"; tab = "jobs" }.buttonStyle(V3ButtonStyle(kind:.ghost))
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    /// 资料预览页（08）：页头的 ⋯ 菜单沿用本页的重命名 / 移动 / 管理关联 / 删除弹窗，改完换 `refresh` 让预览页重读。
    private func viewer(_ id:String) -> some View {
        DatasetViewerPage(datasetID:id,api:session.api,reload:refresh,trail:viewerTrail,back:{ go("home") },
                          rename:{ show("rename",$0.raw) },
                          move:{ selected = [$0.id]; show("move") },
                          associate:{ show("associate",$0.raw); Task { await loadSessions() } },
                          remove:{ selected = [$0.id]; show("deleteBatch") },
                          practice:{ record in
                              guard let source = DatasetViewer.experienceSource(record) else { return }
                              router?.jump(.mock(PracticeFocus(kind:"experience",ref:source.entry,label:record.displayName,resumeID:source.resume,scope:"packaged")))
                          })
    }
    /// 资料路径：属于某条求职进程的写「求职进程 / 公司 · 岗位」，在项目里的写「我的项目 / 项目名」，否则「全部文件」。
    private func viewerTrail(_ record:DatasetRecord) -> [DatasetViewerCrumb] {
        if let project = jobProjects.first(where:{ $0.nodes.contains { $0.datasets.contains { $0.id == record.id } } }) {
            return [DatasetViewerCrumb(label:"求职进程") { go("home"); tab = "jobs" }, DatasetViewerCrumb(label:project.name) { go("app:" + project.id) }]
        }
        let folder = record.raw.text("folder_id")
        guard DatasetRequest.id(folder) else { return [DatasetViewerCrumb(label:"全部文件") { go("files") }] }
        let name = record.raw.text("folder_name").nonEmptyValue ?? folders.first { $0.text("id") == folder }?.text("name") ?? "项目"
        return [DatasetViewerCrumb(label:"我的项目") { go("home"); tab = "mine" }, DatasetViewerCrumb(label:name) { go(folder) }]
    }
    /// 空状态（06.01 / 06.02）：去掉灰底舞台的三张纸（求职进程多一枚录音条）→ 17 中粗标题 → 两行 13 灰字 → 31 高胶囊按钮；不放黑色按钮。
    private func blank<Actions:View>(title:String,lines:[String],audio:Bool = false,@ViewBuilder actions:() -> Actions) -> some View {
        VStack(spacing:0) {
            emptyArt(audio:audio)
            Text(title).font(V3.sans(17,weight:.medium)).foregroundStyle(Color(hex:0x1A1A1A)).frame(height:20).padding(.top,22)
            VStack(spacing:5) { ForEach(lines,id:\.self) { Text($0).frame(height:16) } }.font(V3.sans(13)).foregroundStyle(Color(hex:0x6E6E6A)).padding(.top,11)
            HStack(spacing:9) { actions() }.padding(.top,27)
        }.frame(maxWidth:.infinity).padding(.top,132).padding(.bottom,40)
    }
    /// 06 插图：三张 86×111 的纸（PDF / DOCX / PDF，两侧轻转），求职进程在右下压一枚「12:40」录音条。
    private func emptyArt(audio:Bool) -> some View {
        ZStack(alignment:.topLeading) {
            bigSheet("PDF",V3.red,lines:[62,54,62,46,57]).rotationEffect(.degrees(-2)).offset(x:22,y:11)
            bigSheet("DOCX",Color(hex:0x406BD9),lines:[62,54,62,46,57]).offset(x:97,y:0)
            bigSheet("PDF",V3.red,lines:[62,54,62,46,57]).rotationEffect(.degrees(2)).offset(x:173,y:8)
            if audio {
                HStack(spacing:7) {
                    HStack(alignment:.center,spacing:2.5) { ForEach(Array([8,15,11,19,12,7,14].enumerated()),id:\.offset) { _,h in RoundedRectangle(cornerRadius:1.35).fill(V3.blue).frame(width:3,height:CGFloat(h)) } }
                    Text("12:40").font(V3.number(13.5,weight:.medium)).foregroundStyle(Color(hex:0x6E6E6A))
                }.padding(.horizontal,14).frame(height:35).background(.white,in:Capsule()).overlay(Capsule().stroke(V3.cl,lineWidth:1.35)).offset(x:189,y:78)
            }
        }.frame(width:281,height:122,alignment:.topLeading).accessibilityHidden(true)
    }
    private func bigSheet(_ tag:String,_ color:Color,lines:[Int]) -> some View {
        ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:6.75).fill(.white).overlay(RoundedRectangle(cornerRadius:6.75).stroke(Color(hex:0xE3E3DF),lineWidth:0.7))
            RoundedRectangle(cornerRadius:2).fill(V3.txt).frame(width:38,height:4).offset(x:13,y:13)
            ForEach(Array(lines.enumerated()),id:\.offset) { index,w in RoundedRectangle(cornerRadius:1.35).fill(Color(hex:0xE3E3DF)).frame(width:CGFloat(w),height:3).offset(x:13,y:CGFloat(26 + index * 8)) }
            Text(tag).font(V3.number(8.8,weight:.regular)).foregroundStyle(.white).padding(.horizontal,6).frame(minWidth:32).frame(height:16).background(color,in:RoundedRectangle(cornerRadius:4)).offset(x:22,y:78)
        }.frame(width:86,height:111,alignment:.topLeading)
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
    private func formatIcon(_ item:DatasetRecord,tinted:Bool = true,size:CGFloat = 32) -> some View {
        let tone = formatTone(item)
        return Text(tone.label).font(V3.number(tone.label.count > 3 ? 7 : 8,weight:.regular)).foregroundStyle(tone.color)
            .frame(width:size,height:size).background(tinted ? tone.tint : V3.field,in:RoundedRectangle(cornerRadius:size / 4)).accessibilityHidden(true)
    }
    /// 加载失败（15 页 01 · D）：一行灰字 + 蓝色「重新加载」。
    private var loadFailed: some View {
        V3LoadFailed(message:"资料没有加载出来。") { refresh = UUID() }.padding(.top,view == "home" ? 8 : 24)
    }
    /// 15 页「加载中 · 资料库 · 项目首页」92:5510：标签照常，六张卡片骨架（舞台里两三张白纸 + 名称与计数两道灰条 + ⋯）。
    private var homeSkeleton: some View {
        grid {
            ForEach(0..<6,id:\.self) { index in
                VStack(alignment:.leading,spacing:0) {
                    ZStack {
                        HStack(spacing:-8) { ForEach(0..<(index % 3 == 2 ? 2 : 3),id:\.self) { _ in RoundedRectangle(cornerRadius:4).fill(.white).frame(width:60,height:78).shadow(color:.black.opacity(0.05),radius:3,y:2) } }.offset(y:6)
                    }.frame(maxWidth:.infinity).frame(height:118).background(LibraryTone.stage,in:RoundedRectangle(cornerRadius:10))
                    HStack { V3Skeleton(width:[80,80,80,106,80,80][index],height:8); Spacer(); Image(systemName:"ellipsis").font(.system(size:11)).foregroundStyle(V3.fnt2) }.padding(.horizontal,6).padding(.top,17)
                    V3Skeleton(width:[38,38,38,38,38,58][index],height:7).padding(.horizontal,6).padding(.top,13)
                }
                .padding(8).frame(height:189,alignment:.top)
                .background(.white,in:RoundedRectangle(cornerRadius:13.5)).overlay(RoundedRectangle(cornerRadius:13.5).stroke(V3.line))
            }
        }.accessibilityElement().accessibilityLabel("正在加载资料…")
    }
    private var jobCardSkeleton: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) { V3Skeleton(width:32,height:32,radius:8); VStack(alignment:.leading,spacing:8) { V3Skeleton(width:72,height:9); V3Skeleton(width:104,height:8) } }
            V3Skeleton(width:138,height:8).padding(.top,22)
            HStack { V3Skeleton(width:92,height:8); Spacer(); V3Skeleton(width:44,height:8) }.padding(.top,22)
        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).frame(height:131,alignment:.top)
            .background(.white,in:RoundedRectangle(cornerRadius:13.5)).overlay(RoundedRectangle(cornerRadius:13.5).stroke(Color(hex:0xE8E8E4)))
    }
    /// 15 页「加载中 · 资料库 · 我的项目详情 / 全部文件」：表头之下八行骨架（格式块 + 名称 + 关联 / 大小 / 日期三道短条 + ⋯）。
    private var listSkeleton: some View {
        VStack(alignment:.leading,spacing:0) {
            ForEach(0..<8,id:\.self) { index in
                HStack(spacing:0) {
                    V3Skeleton(width:32,height:32,radius:8)
                    V3Skeleton(width:[104,104,127,106,84,95,113,104][index],height:8).padding(.leading,12)
                    Spacer(minLength:0)
                    V3Skeleton(width:index == 4 ? 85 : 34,height:7).frame(width:190,alignment:.leading)
                    V3Skeleton(width:index == 2 || index == 3 || index == 6 ? 24 : 36,height:7).frame(width:66,alignment:.trailing)
                    V3Skeleton(width:30,height:7).frame(width:144,alignment:.trailing)
                    Image(systemName:"ellipsis").font(.system(size:11)).foregroundStyle(V3.fnt2).frame(width:42,alignment:.trailing)
                }.padding(.leading,12).padding(.trailing,10).frame(height:49)
            }
        }.padding(.top,46).accessibilityElement().accessibilityLabel("正在加载资料…")
    }
    /// 列表（10 页 04.01）：表头 11 号灰字（名称 / 关联或所在项目 / 大小 / 上传日期），上下 1px 线；每行 60 高：
    /// 32 格式块 → 13 中粗名称 + 11 号状态（处理中蓝、失败红）→ 关联 → 大小 → 日期（失败时为「重试」）→ ⋯；
    /// 行间细线从名称处开始。悬停不加底色，只把 ⋯ 换成带描边的小按钮。上传中的文件排在最前面（05.03）。底部是虚线拖放区。
    @ViewBuilder private var fileList: some View {
        let inside = view == "files" ? datasets : datasets.filter { $0.folder == view }
        let uploads = queue.filter { $0.upload.folder == view && $0.status != "accepted" }
        if view != "files" && inside.isEmpty && uploads.isEmpty {
            blank(title:"还没有资料",lines:["把与这个项目相关的文件直接拖到这里，","或者从本地上传、从资料库里挑几份移进来。"]) {
                Button("上传本地文件") { show("upload") }.buttonStyle(ChipStyle()).disabled(batchMode)
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
                .font(V3.sans(11)).foregroundStyle(LibraryTone.faint).frame(height:13).padding(.leading,12).padding(.trailing,10).padding(.top,23).frame(height:45,alignment:.top)
                .overlay(alignment:.bottom) { Rectangle().fill(V3.line).frame(height:1) }
                VStack(spacing:6) {
                    ForEach(uploads) { uploadRow($0) }
                    if visible.isEmpty && uploads.isEmpty { Text(query.isEmpty ? "还没有资料。" : "没有匹配的资料。").font(V3.sans(13)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).padding(.vertical,40) }
                    ForEach(Array(visible.enumerated()),id:\.element.id) { index,item in
                        fileRow(item).overlay(alignment:.top) { if index > 0 || !uploads.isEmpty { Rectangle().fill(V3.line).frame(height:1).padding(.leading,68).offset(y:-3.5) } }
                    }
                }.padding(.top,5)
                if DatasetRequest.id(view) {
                    Button { show("upload") } label:{
                        VStack(spacing:5) {
                            HStack(spacing:8) { Image(systemName:"arrow.up.to.line").font(.system(size:11,weight:.medium)); Text("拖入文件，或点击上传到「\(folderName)」") }.font(V3.sans(12.5,weight:.medium)).foregroundStyle(V3.sub).frame(height:15)
                            Text(limitText).font(V3.sans(10.5)).foregroundStyle(LibraryTone.faint).frame(height:13)
                        }.frame(maxWidth:.infinity).frame(height:51).contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius:9.5).stroke(V3.fnt2,style:StrokeStyle(lineWidth:1,dash:[4,4])))
                    }.buttonStyle(.plain).padding(.top,14).disabled(busy || batchMode || !loaded)
                }
            }
        }
    }
    private var limitText: String {
        "PDF、DOCX、Markdown、TXT 最大 \(JobProjects.size(limits["max_file_bytes"]?.numberValue ?? 20*1024*1024))；音视频最大 \(JobProjects.size(Double(maximum)))"
    }
    /// 上传中的一行（05.03）：浅底 #F8F8F6 圆角 8；名称下 240 宽进度条（无字节进度时为整段流动条），右侧蓝色状态，
    /// 同名冲突 / 失败时换成红字与「保留两份 / 替换 / 重试 / 移出」文字按钮。
    private func uploadRow(_ item:LibraryQueued) -> some View {
        let record = DatasetRecord(.object(["file_name":.string(item.upload.name),"file_format":.string(URL(fileURLWithPath:item.upload.name).pathExtension),"asset_kind":.string(["webm","m4a","mp3","wav","ogg","mp4","mov"].contains(URL(fileURLWithPath:item.upload.name).pathExtension.lowercased()) ? "audio" : "document")]))
        let failed = ["conflict","rejected","unknown"].contains(item.status)
        return HStack(spacing:0) {
            formatIcon(record)
            VStack(alignment:.leading,spacing:6) {
                Text(item.upload.name).font(V3.sans(13.5,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height:16)
                if item.status == "uploading" { LibraryProgressBar().frame(width:240,height:3) }
                else { Text(item.message).font(V3.sans(11)).foregroundStyle(failed ? V3.red : LibraryTone.faint).lineLimit(1).frame(height:13) }
            }.padding(.horizontal,14).frame(maxWidth:.infinity,alignment:.leading)
            Group {
                switch item.status {
                case "uploading": Text("正在上传…").foregroundStyle(V3.blue)
                case "conflict": Button("处理同名") { conflictID = item.id }.buttonStyle(.plain).foregroundStyle(V3.txt)
                case "selected": Text("等待上传").foregroundStyle(LibraryTone.faint)
                default: Button("重试") { startUpload() }.buttonStyle(.plain).foregroundStyle(V3.txt).disabled(busy)
                }
            }.font(V3.sans(12)).frame(width:190,alignment:.leading)
            Text(ByteCountFormatter.string(fromByteCount:Int64((try? item.upload.file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0),countStyle:.file)).font(V3.sans(12)).foregroundStyle(LibraryTone.faint).frame(width:66,alignment:.trailing)
            Text("刚刚").font(V3.sans(12)).foregroundStyle(LibraryTone.faint).frame(width:144,alignment:.trailing)
            Group {
                if item.status != "uploading" {
                    Button("移出") { item.upload.discard(); queue.removeAll { $0.id == item.id } }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(V3.sub).disabled(busy)
                }
            }.frame(width:42,alignment:.trailing)
        }
        .padding(.leading,12).padding(.trailing,10).frame(height:52)
        .background(LibraryTone.row,in:RoundedRectangle(cornerRadius:8))
    }
    /// `datasetRowMeta`: format name when ready, otherwise the status (blue while processing, red when failed).
    private func rowMeta(_ item:DatasetRecord) -> (String,Color) {
        if item.media {
            if item.raw.text("upload_status") == "failed" { return ("上传失败",V3.red) }
            if item.raw.text("upload_status") == "uploading" { return ("正在上传…",V3.blue) }
            if item.raw.text("asset_kind") == "audio" {
                let state = ["queued":"等待转写","processing":"正在转写…","failed":"转写失败"][item.raw.text("parse_status")] ?? (item.raw["has_transcript"]?.bool == true ? "转写完成" : "点击播放")
                return ("音频 · " + state,LibraryTone.faint)
            }
            return ("视频 · 点击下载",LibraryTone.faint)
        }
        if item.raw.text("parse_status") == "failed" || item.raw.text("upload_status") == "failed" {
            let reason = item.raw.text("failure_reason")
            let label = ["format_unsupported":"文件格式不受支持","content_invalid":"文件内容无效","size_exceeded":"文件内容超出解析限制","service_unavailable":"解析服务暂不可用","timeout":"解析超时","quota_exceeded":"当前资料数量已达上限"][reason]
            return (label.map { "解析失败 · " + $0 } ?? "解析失败",V3.red)
        }
        if item.raw.text("parse_status") == "queued" { return ("等待解析",V3.blue) }
        if item.busy { return ("正在解析…",V3.blue) }
        return (["MD":"Markdown","PDF":"PDF","DOCX":"Word","TXT":"纯文本"][item.format] ?? item.format,LibraryTone.faint)
    }
    private func fileRow(_ item:DatasetRecord) -> some View {
        let meta = rowMeta(item)
        let failed = meta.1 == V3.red && !item.media
        let hovered = hoveredRow == item.id
        return HStack(spacing:0) {
            formatIcon(item)
            VStack(alignment:.leading,spacing:4) {
                Text(item.displayName).font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height:16).help(item.name)
                Text(meta.0).font(V3.sans(11)).foregroundStyle(meta.1).lineLimit(1).frame(height:13)
            }.padding(.horizontal,12).frame(maxWidth:.infinity,alignment:.leading)
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
                    } label:{
                        Image(systemName:"ellipsis").font(.system(size:12,weight:.medium)).foregroundStyle(hovered ? V3.txt : LibraryTone.faint).frame(width:27,height:27)
                            .background(hovered ? Color.white : .clear,in:RoundedRectangle(cornerRadius:6.5)).overlay(RoundedRectangle(cornerRadius:6.5).stroke(hovered ? V3.cl : .clear))
                    }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy).accessibilityLabel("打开「\(item.displayName)」操作菜单")
                }
            }.frame(width:42,alignment:.trailing)
        }
        .padding(.leading,12).padding(.trailing,10).frame(height:54)
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
        guard !busy, !account.isEmpty else { return }
        target = item; action = kind; sheetError = nil; name = kind == "renameFolder" ? item.text("name") : kind == "createFolder" ? "" : item.text("file_name"); descriptionText = ""; pickQuery = ""; picked = []
        destination = kind == "associate" ? item.text("interview_session_id") : kind == "move" ? "" : folders.first?.text("id") ?? ""
    }
    /// 弹窗外壳（10 页 02.01 / 03.01–03.03）：左右 31、顶部 30 内边距；20 号衬线标题、12.5 灰字说明（距标题 4）；
    /// 底部 88 高的按钮行带顶部分隔线，按钮一律靠右（32 高：Bordered「取消」+ 墨黑主按钮），管理关联左侧放红字「取消关联」。
    private var sheet: some View {
        let kind = action ?? ""
        let width: CGFloat = kind == "upload" ? 560 : kind == "associate" ? 540 : ["move","pick","createFolder"].contains(kind) ? 480 : 440
        return VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:0) {
                Text(sheetTitle).font(V3.serif(20)).foregroundStyle(V3.txt).lineLimit(1).frame(height:29)
                if let description = sheetDescription {
                    Text(description).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(["associate","pick","move"].contains(kind) ? 1 : nil).fixedSize(horizontal:false,vertical:true).padding(.top,4)
                }
                VStack(alignment:.leading,spacing:0) { sheetContent }.padding(.top,22)
                if let sheetError { Text(sheetError).foregroundStyle(V3.red).font(V3.sans(11.5)).padding(.top,12) }
            }
            .padding(.horizontal,kind == "createFolder" ? 23 : 31).padding(.top,kind == "createFolder" ? 26 : 30).padding(.bottom,kind == "createFolder" ? 20 : 32)
            if kind != "createFolder" { Rectangle().fill(V3.line).frame(height:1) }
            HStack(spacing:10) {
                if kind == "associate" && !target.text("interview_session_id").isEmpty {
                    Button("取消关联") { Task { await save(unlink:true) } }.buttonStyle(.plain).font(V3.sans(12,weight:.medium)).foregroundStyle(V3.red).disabled(busy)
                }
                if kind == "createFolder" { Text("求职进程的项目会自动生成，无需手动创建").font(V3.sans(11.5)).foregroundStyle(LibraryTone.faint).lineLimit(1) }
                if kind == "upload" { Text(stagedSummary).font(V3.sans(11.5)).foregroundStyle(LibraryTone.faint).lineLimit(1) }
                Spacer(minLength:0)
                Button("取消") { if kind == "upload" { discardStaged() }; action = nil }.buttonStyle(V3ButtonStyle(kind:.ghost,height:36,width:79)).disabled(busy)
                Button(busy ? "处理中…" : confirmLabel) { if kind == "upload" { confirmUpload() } else { Task { await save() } } }
                    .buttonStyle(V3ButtonStyle(kind:["deleteFolder","deleteBatch"].contains(kind) ? .danger : .dark,height:36))
                    .disabled(busy || (loading && kind != "upload") || confirmDisabled)
            }.padding(.horizontal,kind == "createFolder" ? 23 : 31).frame(height:kind == "createFolder" ? 64 : 88)
        }
        .frame(width:width).frame(maxHeight:760)
        .background { Button("") { if !busy { if kind == "upload" { discardStaged() }; action = nil } }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) } // 不画 ×，Esc 关闭
        .interactiveDismissDisabled(busy)
    }
    private var sheetTitle: String {
        switch action {
        case "deleteFolder": return "删除项目「\(target.text("name"))」及其中的资料？"
        case "move": return selected.count == 1 ? "移动资料到项目" : "移动 \(selected.count) 份资料到项目"
        case "deleteBatch": return selected.count == 1 ? "永久删除「\(datasets.first { selected.contains($0.id) }?.name ?? "资料")」？" : "永久删除所选资料（\(selected.count) 份）？"
        default: return ["createFolder":"新建项目","renameFolder":"重命名项目","rename":"重命名资料","associate":"管理关联","pick":"从资料库选择","uploadRename":"保留两份","upload":"上传资料"][action ?? ""] ?? "资料库"
        }
    }
    private var sheetDescription: String? {
        let one = datasets.first { selected.contains($0.id) }?.name ?? ""
        return ["createFolder":"把同一件事的资料放进一个项目，例如一次面试冲刺或一份作品集。","renameFolder":"只修改项目名称，项目内的资料不受影响。","rename":"只修改资料显示名称，不改变文件格式或已保存的内容。",
                "deleteFolder":(target["dataset_count"]?.integer ?? 0) > 0 ? "项目里的 \(target["dataset_count"]?.integer ?? 0) 份资料会和项目一起永久删除（包括源文件和解析结果），无法恢复。想保留的资料，请先移到其他项目。" : "这个项目里没有资料，删除后无法恢复。",
                "move":selected.count == 1 ? "「\(one)」 · 选择目标项目" : "已选择 \(selected.count) 份资料 · 选择目标项目",
                "associate":"「\(target.text("file_name"))」可以关联到一场面试，关联后在求职记录里也能看到它。",
                "pick":"选中的资料会移到「\(folderName)」。",
                "uploadRename":"给新文件换一个名字，和已有的那份同时保留。",
                "upload":"简历附件、证书、作品集、岗位 JD 和面试录音都可以放在这里。"][action ?? ""]
    }
    private var confirmLabel: String {
        ["createFolder":"创建项目","rename":"保存名称","deleteFolder":(target["dataset_count"]?.integer ?? 0) > 0 ? "连同资料一起删除" : "确认删除","deleteBatch":selected.count == 1 ? "永久删除" : "永久删除所选","move":"确定移动","upload":"上传",
         "pick":picked.isEmpty ? "移入项目" : "移入 \(picked.count) 份"][action ?? ""] ?? "保存"
    }
    private var confirmDisabled: Bool {
        switch action {
        case "pick": return picked.isEmpty
        case "move": return !DatasetRequest.id(destination)
        case "associate": return destination.isEmpty || destination == target.text("interview_session_id")
        case "upload": return staged.isEmpty
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
                Text(["createFolder":"项目名称","renameFolder":"项目名称"][action ?? ""] ?? "资料名称").font(V3.sans(action == "createFolder" ? 12.5 : 13,weight:.medium)).foregroundStyle(V3.txt).frame(height:18)
                TextField("",text:Binding(get:{name},set:{ name = action == "createFolder" || action == "renameFolder" ? String($0.prefix(64)) : $0 }),prompt:Text(action == "createFolder" ? "例如：系统设计复习、英文简历与求职信" : "").foregroundStyle(V3.fnt2)).textFieldStyle(.plain).font(V3.sans(13))
                    .padding(.horizontal,12).frame(height:36).background(.white,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.txt.opacity(0.85)))
                    .onSubmit { Task { await save() } }.disabled(busy)
                if action == "createFolder" {
                    HStack(spacing:6) { Text("项目说明").font(V3.sans(12.5,weight:.medium)).foregroundStyle(V3.txt); Text("可选").font(V3.sans(11.5)).foregroundStyle(LibraryTone.faint) }.frame(height:18).padding(.top,14)
                    ZStack(alignment:.topLeading) {
                        if descriptionText.isEmpty { Text("告诉 AI 这个项目的目标，例如：准备字节三面行为面试，回答按 STAR 结构，控制在 2 分钟内。").font(V3.sans(12.5)).foregroundStyle(V3.fnt2).padding(.horizontal,12).padding(.vertical,10).allowsHitTesting(false) }
                        TextEditor(text:Binding(get:{descriptionText},set:{ descriptionText = String($0.prefix(500)) })).font(V3.sans(13)).scrollContentBackground(.hidden).scrollIndicators(.never)
                            .padding(.horizontal,7).padding(.vertical,6).disabled(busy).accessibilityLabel("项目说明")
                    }.frame(height:76).background(.white,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color(hex:0xECECEA)))
                }
            }
        }
        else if action == "upload" { uploadSheet }
        else if action == "move" {
            moveArt.frame(maxWidth:.infinity).frame(height:84).background(LibraryDotStage()).clipShape(RoundedRectangle(cornerRadius:11))
            Text("选择目标项目").font(V3.sans(11)).foregroundStyle(LibraryTone.faint).frame(height:13).padding(.top,20).padding(.bottom,10)
            pickList(maxHeight:228) {
                let current = selected.count == 1 ? datasets.first { selected.contains($0.id) }?.folder : nil
                let others = folders.filter { $0.text("id") != current }
                if others.isEmpty { Text("还没有其他项目").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                ForEach(others,id:\.self) { item in
                    let on = destination == item.text("id")
                    pickRow(checked:on,action:{ destination = item.text("id") }) {
                        LibraryIcon(name:"icon-folder",size:14); Text(item.text("name")).lineLimit(1); Spacer(minLength:0)
                        Text("\(item["dataset_count"]?.integer ?? 0) 份").font(V3.sans(11.5)).foregroundStyle(LibraryTone.faint)
                        if on { Image(systemName:"checkmark").font(.system(size:11,weight:.semibold)).foregroundStyle(V3.txt).padding(.leading,6) }
                    }
                }
            }
        }
        else if action == "pick" {
            LibrarySearchField(text:$pickQuery,placeholder:"搜索资料…",width:nil,height:32).padding(.bottom,10)
            let shown = pickCandidates.filter { pickQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(pickQuery) }
            pickList(maxHeight:300) {
                if shown.isEmpty { Text(pickCandidates.isEmpty ? "资料库里没有可以移入的资料" : "没有匹配的资料。").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                ForEach(shown) { item in
                    let on = picked.contains(item.id)
                    pickRow(checked:on,height:48,action:{ if on { picked.remove(item.id) } else { picked.insert(item.id) } }) {
                        formatIcon(item,size:28); Text(item.name).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                        Text(projectLabels[item.id] ?? "未归入").font(V3.sans(11.5)).foregroundStyle(LibraryTone.faint).lineLimit(1).frame(maxWidth:140,alignment:.trailing)
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
            associateArt.frame(maxWidth:.infinity).frame(height:96).background(LibraryDotStage()).clipShape(RoundedRectangle(cornerRadius:11))
            LibrarySearchField(text:$pickQuery,placeholder:"搜索公司、岗位或轮次…",width:nil,height:36).padding(.top,20)
            HStack { Text("选择要关联的面试"); Spacer(); Text("一份资料只能关联一场") }.font(V3.sans(11)).foregroundStyle(LibraryTone.faint).frame(height:13).padding(.top,20).padding(.bottom,11)
            let current = target.text("interview_session_id")
            let keyword = pickQuery.lowercased()
            let shown = sessions.sorted { a,b in a.text("id") == current ? true : b.text("id") == current ? false : a.text("start_at") > b.text("start_at") }
                .filter { keyword.isEmpty || "\($0.text("company_name")) \($0.text("job_title")) \($0.text("stage_label"))".lowercased().contains(keyword) }
            pickList(height:240) {
                if loading && sessions.isEmpty {
                    // 15 页「加载中 · 资料 · 管理关联」：四行单选占位
                    ForEach(0..<4,id:\.self) { index in
                        HStack(spacing:12) { Circle().stroke(V3.fnt2).frame(width:16,height:16); VStack(alignment:.leading,spacing:8) { V3Skeleton(width:[120,100,96,104][index],height:9); V3Skeleton(width:[150,140,92,110][index],height:7) } ; Spacer() }
                            .padding(.horizontal,12).frame(height:50)
                    }.accessibilityElement().accessibilityLabel("正在读取面试…")
                }
                else if shown.isEmpty { Text(keyword.isEmpty ? "还没有面试安排，可以先在投递看板里添加" : "没有匹配的面试").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxWidth:.infinity).frame(height:78).padding(.vertical,12) }
                ForEach(shown,id:\.self) { item in
                    let on = destination == item.text("id")
                    pickRow(checked:on,height:50,action:{ destination = item.text("id") }) {
                        Circle().fill(on ? V3.txt : .white).overlay(Circle().stroke(on ? V3.txt : V3.fnt2)).overlay { if on { Circle().fill(.white).frame(width:6,height:6) } }.frame(width:16,height:16)
                        VStack(alignment:.leading,spacing:5) {
                            Text("\(item.text("company_name")) · \(item.text("job_title"))").font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1)
                            Text(sessionMeta(item)).font(V3.sans(11)).foregroundStyle(LibraryTone.faint).lineLimit(1)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                        if item.text("id") == current { Text("当前").font(V3.sans(10.5,weight:.medium)).foregroundStyle(V3.sub).padding(.horizontal,8).frame(height:22).background(.white,in:Capsule()).overlay(Capsule().stroke(V3.cl)) }
                    }
                }
            }
        }
    }
    /// 上传资料（02.01）：点状浅灰舞台（虚线内框）里三张小文件 + 录音条，「拖入资料文件，或点击选择」；选中的文件列在下面；
    /// 再下面是「上传到」当前项目。底栏左侧写已选数量。
    @ViewBuilder private var uploadSheet: some View {
        Button { pickStaged() } label:{
            VStack(spacing:0) {
                uploadArt.frame(width:220,height:64)
                Text("拖入资料文件，或点击选择").font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt).frame(height:16).padding(.top,22)
                Text(limitText).font(V3.sans(11)).foregroundStyle(LibraryTone.faint).frame(height:13).padding(.top,8)
            }.frame(maxWidth:.infinity).frame(height:168).contentShape(Rectangle())
            .background(LibraryDotStage()).clipShape(RoundedRectangle(cornerRadius:11))
            .overlay(RoundedRectangle(cornerRadius:10.5).stroke(Color(hex:0xE9E9E5),style:StrokeStyle(lineWidth:1,dash:[5,4])).padding(0.5))
        }.buttonStyle(.plain).disabled(busy).accessibilityLabel("选择要上传的文件")
        .onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
            guard !busy, DatasetRequest.id(view) else { return false }
            let targetFolder = view, owner = account
            for provider in providers { _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in guard owner == account else { return }; await enqueue([url],into:targetFolder,staging:true) } } } }
            return true
        }
        if !staged.isEmpty {
            VStack(spacing:6) {
                ForEach(staged) { item in
                    HStack(spacing:10) {
                        formatIcon(DatasetRecord(.object(["file_name":.string(item.upload.name),"file_format":.string(URL(fileURLWithPath:item.upload.name).pathExtension)])),size:28)
                        Text(item.upload.name).font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                        Text(ByteCountFormatter.string(fromByteCount:Int64((try? item.upload.file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0),countStyle:.file)).font(V3.sans(11)).foregroundStyle(LibraryTone.faint)
                        Button { item.upload.discard(); staged.removeAll { $0.id == item.id } } label:{ Image(systemName:"xmark").font(.system(size:9,weight:.semibold)).foregroundStyle(LibraryTone.faint).frame(width:18,height:18) }
                            .buttonStyle(.plain).accessibilityLabel("移除「\(item.upload.name)」")
                    }.frame(height:28)
                }
            }.padding(.top,12)
        }
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:5) {
                Text("上传到").font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt)
                Text("当前项目，之后可以移动到别的项目").font(V3.sans(11)).foregroundStyle(LibraryTone.faint)
            }
            Spacer(minLength:0)
            HStack(spacing:6) { LibraryIcon(name:"icon-folder",size:13); Text(folderName).font(V3.sans(12,weight:.medium)).foregroundStyle(V3.txt).lineLimit(1) }
        }.padding(.horizontal,17).frame(height:59).background(.white,in:RoundedRectangle(cornerRadius:11.5)).overlay(RoundedRectangle(cornerRadius:11.5).stroke(V3.cl)).padding(.top,20)
    }
    private var stagedSummary: String { staged.isEmpty ? "未选择文件" : "已选择 \(staged.count) 个文件" }
    /// 02.01 舞台插图：PDF / JD / 证书三张小纸 + 黑点录音条。
    private var uploadArt: some View {
        ZStack(alignment:.topLeading) {
            miniDoc("PDF",V3.orange).offset(x:0,y:6)
            miniDoc("JD",V3.blue).offset(x:46,y:0)
            miniDoc("证书",V3.green).offset(x:90,y:5)
            HStack(spacing:6) {
                Circle().fill(V3.txt).frame(width:11,height:11)
                HStack(alignment:.center,spacing:2) { ForEach(Array([4,9,12,8,5,5].enumerated()),id:\.offset) { _,h in RoundedRectangle(cornerRadius:1).fill(V3.sub).frame(width:2,height:CGFloat(h)) } }
            }.padding(.horizontal,9).frame(height:28).background(.white,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(V3.cl)).shadow(color:.black.opacity(0.05),radius:4,y:2).offset(x:152,y:22)
        }.frame(width:220,height:64,alignment:.topLeading).accessibilityHidden(true)
    }
    private func miniDoc(_ tag:String,_ color:Color) -> some View {
        ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:4).fill(.white).overlay(RoundedRectangle(cornerRadius:4).stroke(V3.cl)).shadow(color:.black.opacity(0.05),radius:4,y:2)
            RoundedRectangle(cornerRadius:2).fill(V3.sk2).frame(width:24,height:3).offset(x:6,y:8)
            RoundedRectangle(cornerRadius:1.5).fill(V3.line).frame(width:30,height:2.5).offset(x:6,y:16)
            RoundedRectangle(cornerRadius:1.5).fill(V3.line).frame(width:22,height:2.5).offset(x:6,y:22)
            Text(tag).font(V3.sans(6.5,weight:.medium)).foregroundStyle(.white).padding(.horizontal,5).frame(height:11).background(color,in:RoundedRectangle(cornerRadius:2.5)).offset(x:4,y:44)
        }.frame(width:44,height:58,alignment:.topLeading)
    }
    /// 03.02 舞台插图：资料小纸 → 虚线箭头 → 目标项目文件夹（选中后写项目名）。
    private var moveArt: some View {
        let one = datasets.first { selected.contains($0.id) }
        let tone: (label:String,color:Color,tint:Color) = one.map(formatTone) ?? (label:"FILE",color:V3.sub,tint:V3.field)
        let targetName = folders.first { $0.text("id") == destination }?.text("name") ?? "目标项目"
        return HStack(spacing:14) {
            ZStack(alignment:.topLeading) {
                RoundedRectangle(cornerRadius:5).fill(.white).overlay(RoundedRectangle(cornerRadius:5).stroke(V3.cl))
                RoundedRectangle(cornerRadius:2).fill(V3.sk2).frame(width:23,height:4).offset(x:6,y:9)
                RoundedRectangle(cornerRadius:1.5).fill(V3.line).frame(width:29,height:3).offset(x:5,y:18)
                RoundedRectangle(cornerRadius:1.5).fill(V3.line).frame(width:21,height:3).offset(x:4,y:25)
                Text(tone.label).font(V3.number(7,weight:.medium)).foregroundStyle(.white).padding(.horizontal,4).frame(minWidth:24).frame(height:13).background(tone.color,in:RoundedRectangle(cornerRadius:3)).offset(x:3,y:34)
            }.frame(width:42,height:54).shadow(color:.black.opacity(0.05),radius:4,y:2)
            HStack(spacing:4) { Path { $0.move(to:.zero); $0.addLine(to:CGPoint(x:34,y:0)) }.stroke(V3.fnt2,style:StrokeStyle(lineWidth:1.2,dash:[3,3])).frame(width:34,height:1); Image(systemName:"chevron.right").font(.system(size:8,weight:.medium)).foregroundStyle(V3.fnt2) }
            ZStack {
                Image(systemName:"folder").font(.system(size:56,weight:.ultraLight)).foregroundStyle(Color(hex:0xB9B9B3))
                Text(targetName).font(V3.sans(9.5,weight:.medium)).foregroundStyle(V3.sub).lineLimit(1).frame(width:50).offset(y:4)
            }.frame(width:68,height:54)
        }.accessibilityHidden(true)
    }
    private func load(poll:Bool = false) async {
        let generation = UUID(); loadID = generation
        guard !account.isEmpty else { loaded = true; return }; loading = true; error = nil
        do {
            var attempt = 0, withFolders = true
            repeat {
                // 轮询时只重读资料列表；有资料处理完（处理中的变少）才连资料夹一起重读
                async let files = request("/api/datasets")
                let group: JSONValue? = withFolders ? try await request("/api/datasets/folders") : nil
                let data = try await files; try Task.checkCancellation(); guard active, loadID == generation else { return }
                let wasBusy = Set(datasets.filter(\.busy).map(\.id))
                datasets = (data["datasets"]?.items ?? []).map(DatasetRecord.init); limits = data["limits"] ?? .null; loaded = true; loading = false; selected.formIntersection(datasets.map(\.id))
                if let group { folders = group["folders"]?.items ?? [] }
                if DatasetRequest.id(view) && !folders.contains(where:{$0.text("id")==view}) { view = "home"; tab = "mine" }
                withFolders = !wasBusy.isSubset(of: Set(datasets.filter(\.busy).map(\.id)))
                if withFolders && attempt > 0 { await session.api.purgeCache() }
                if !poll || !datasets.contains(where:{$0.busy}) { break }
                // 有资料在处理：3 秒起逐步放慢到 20 秒，App 不在前台时暂停
                guard await Polling.wait(attempt,first:3,cap:20,topic:"parse_task") else { break }; attempt += 1
            } while !Task.isCancelled
        } catch { if active && loadID == generation && !(error is CancellationError) { self.error = explain(error) } }
        if active && loadID == generation && !Task.isCancelled { loading = false }
    }
    private func mutate(_ path:String,_ method:String,_ body:JSONValue? = nil,query:[String:String] = [:]) async { guard !busy else { return }; busy = true; error = nil; do { _ = try await request(path,method,body,query:query); notice = .done("已保存"); await load() } catch { if !(error is CancellationError) { self.error = explain(error) } }; busy = false; refresh = UUID() }
    private func save(unlink:Bool = false) async {
        guard !busy else { return }; busy = true; sheetError = nil
        var restart = false
        do {
            switch action {
            case "createFolder":
                let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines), about = descriptionText.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !trimmed.isEmpty else { sheetError = "项目名称不能为空"; busy = false; return }
                guard !trimmed.contains("/") && !trimmed.contains("\\") else { sheetError = "项目名称不能包含斜杠符号"; busy = false; return }
                var body: [String: JSONValue] = ["name":.string(trimmed)]; if !about.isEmpty { body["description"] = .string(about) }
                _ = try await request("/api/datasets/folders","POST",.object(body)); notice = .done("项目「\(trimmed)」已创建")
            case "pick":
                guard DatasetRequest.id(view), !picked.isEmpty else { throw APIError.invalidResponse }
                _ = try await request("/api/datasets/move-batch","POST",.object(["folder_id":.string(view),"dataset_ids":.array(picked.sorted().map(JSONValue.string))]))
                notice = .done("已移入 \(picked.count) 份资料"); picked = []
            case "renameFolder": _ = try await request("/api/datasets/folders/" + target.text("id"),"PATCH",.object(["name":.string(name)]))
            case "rename": _ = try await request("/api/datasets/" + target.text("id"),"PATCH",.object(["name":.string(name)]))
            case "move": guard DatasetRequest.id(destination) else { throw APIError.invalidResponse }; _ = try await request("/api/datasets/move-batch","POST",.object(["folder_id":.string(destination),"dataset_ids":.array(selected.sorted().map(JSONValue.string))])); selected = []; notice = .done("已移动到「\(folders.first { $0.text("id") == destination }?.text("name") ?? "项目")」")
            case "deleteFolder": _ = try await request("/api/datasets/folders/" + target.text("id"),"DELETE",query:["confirm_contents":"true"])
            case "deleteBatch":
                var failures:[String] = []; var removed = 0
                for item in datasets.filter({selected.contains($0.id)}) { do { _ = try await request("/api/datasets/" + item.id,"DELETE"); selected.remove(item.id); removed += 1; if view == "ds:" + item.id { view = DatasetRequest.id(item.folder) ? item.folder : "files" } } catch { if error is CancellationError { throw error }; failures.append(item.name + "：" + explain(error)) } }
                notice = failures.isEmpty ? .done("已删除 \(removed) 份资料") : .attention("已删除 \(removed) 份资料", "\(failures.count) 份没有删除，原因见弹窗"); if !failures.isEmpty { throw APIError.server(status:409,code:failures.joined(separator:"；")) }
            case "associate":
                let old = target.text("interview_session_id"), id = target.text("id")
                if !old.isEmpty && (unlink || old != destination) { _ = try await request("/api/interview-sessions/" + old + "/assets/" + id,"DELETE"); target = .object(["id":.string(id),"file_name":target["file_name"] ?? .null]); notice = .done("旧关联已解除") }
                if !unlink && destination != old { guard DatasetRequest.id(destination) else { throw APIError.invalidResponse }; _ = try await request("/api/interview-sessions/" + destination + "/assets/attach","POST",.object(["dataset_id":.string(id)])) }
            case "uploadRename":
                guard let index = queue.firstIndex(where:{$0.id==queueID}), !name.isEmpty else { throw APIError.invalidResponse }
                let ext = URL(fileURLWithPath:queue[index].upload.name).pathExtension
                queue[index].upload.name = name.lowercased().hasSuffix("." + ext.lowercased()) ? name : name + "." + ext; queue[index].upload = queue[index].upload.rekey(); queue[index].status = "selected"; queue[index].message = "等待重新上传"; restart = true
            default: break
            }
            action = nil; await load()
        } catch { if !(error is CancellationError) { sheetError = explain(error); await load() } }
        busy = false; refresh = UUID()
        if restart { startUpload() }
    }
    private func loadSessions() async {
        loading = true; do { var values:[JSONValue] = [], cursor = ""; var seen = Set<String>(); repeat { var query = ["limit":"500"]; if !cursor.isEmpty { query["cursor"] = cursor }; let data = try await request("/api/interview-sessions",query:query); values += data["items"]?.items ?? []; cursor = data.text("next_cursor"); if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse } } while !cursor.isEmpty; sessions = values } catch { if !(error is CancellationError) { sheetError = explain(error) } }; loading = false
    }
    /// 所有类型都进资料预览页（08）；没处理完的先提示。
    private func open(_ item:DatasetRecord) { guard !busy else { return }; if !item.ready { notice = .attention("「\(item.displayName)」\(item.status)", "处理完成后才能打开预览"); return }; go("ds:" + item.id) }
    /// 上传弹窗里点舞台：系统文件面板，选中的文件先放进 `staged`，点「上传」才开始。
    private func pickStaged() { guard !busy, !account.isEmpty, DatasetRequest.id(folder) else { return }; let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; let configured = (limits["allowed_extensions"]?.items ?? []) + (limits["media_allowed_extensions"]?.items ?? []); let extensions = configured.compactMap(\.stringValue); panel.allowedContentTypes = (extensions.isEmpty ? ["pdf","docx","md","txt","webm","m4a","mp3","wav","ogg","mp4","mov"] : extensions).compactMap{UTType(filenameExtension:$0.trimmingCharacters(in:CharacterSet(charactersIn:".")))}; guard panel.runModal() == .OK else { return }; let targetFolder = folder; Task { await enqueue(panel.urls,into:targetFolder,staging:true) } }
    private func enqueue(_ urls:[URL],into targetFolder:String,staging:Bool = false) async {
        let owner = account; guard !owner.isEmpty else { return }
        let batch = max(1,limits["max_files_per_batch"]?.integer ?? 10)
        func pendingCount() -> Int { staging ? staged.count : queue.filter{$0.status != "accepted"}.count }
        for url in urls.prefix(max(0,batch - pendingCount())) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { let media = ["webm","m4a","mp3","wav","ogg","mp4","mov"].contains(url.pathExtension.lowercased()); let limit = media ? maximum : min(maximum,Int64(limits["max_file_bytes"]?.numberValue ?? 20*1024*1024)); let upload = try await Task.detached { try DatasetUpload.snapshot(url,folder:targetFolder,limit:limit) }.value; guard active, owner == account, pendingCount() < batch else { upload.discard(); return }; if staging { staged.append(LibraryQueued(upload:upload)) } else { queue.append(LibraryQueued(upload:upload)) } } catch { if active && owner == account { if staging { sheetError = "\(url.lastPathComponent)：" + explain(error) } else { self.error = "\(url.lastPathComponent)：" + explain(error) } } }
        }
        if urls.count > batch { notice = .attention("每批最多 \(batch) 个文件", "超出部分没有加入，可以分几次上传。") }
    }
    /// 02.01「上传」：已选文件转入上传队列并开始上传，弹窗关闭，进度在列表最上方。
    private func confirmUpload() { guard !staged.isEmpty else { return }; queue += staged; staged = []; action = nil; startUpload() }
    private func discardStaged() { staged.forEach { $0.upload.discard() }; staged = [] }
    private func startUpload() { guard active, !busy, queue.contains(where:{ ["selected","unknown","rejected"].contains($0.status) }) else { return }; uploadTask = Task { await uploadAll() } }
    /// 02.02 同名冲突：文档可以替换（保留资料 ID、项目和面试关联），音视频只能保留两份。
    private var conflictItem: LibraryQueued? { queue.first { $0.id == conflictID } }
    private var conflictExisting: DatasetRecord? {
        guard let item = conflictItem else { return nil }
        return datasets.first { $0.folder == item.upload.folder && $0.name.precomposedStringWithCanonicalMapping == item.upload.name.precomposedStringWithCanonicalMapping }
    }
    private var conflictMessage: String {
        guard let item = conflictItem else { return "" }
        return conflictExisting.map { !$0.media } == true ? "「\(item.upload.name)」已经存在。替换后，引用它的对话和求职记录会改用新文件。" : "「\(item.upload.name)」已经存在，可以改个名字保留两份。"
    }
    @ViewBuilder private var conflictActions: some View {
        if let existing = conflictExisting, !existing.media {
            Button("替换") { replaceConflict(existing) }
        }
        Button("保留两份") { let id = conflictID; conflictID = nil; keepBoth(id) }.buttonStyle(LibraryAlertGrayStyle())
        Button("取消",role:.cancel) { conflictID = nil }
    }
    private func replaceConflict(_ existing:DatasetRecord) {
        guard let index = queue.firstIndex(where:{$0.id == conflictID}) else { return }
        queue[index].upload.replacing = existing.id; queue[index].upload.revision = existing.raw.text("content_revision"); queue[index].upload.name = existing.name
        queue[index].upload = queue[index].upload.rekey(); queue[index].status = "selected"; queue[index].message = "已确认替换，等待上传"
        conflictID = nil; startUpload()
    }
    private func keepBoth(_ id:UUID?) {
        guard let id, let item = queue.first(where:{$0.id == id}) else { return }
        queueID = id; show("uploadRename"); name = item.upload.name
    }
    private func uploadAll() async {
        guard !busy else { return }; let owner = account; busy = true; error = nil
        for id in queue.filter({["selected","unknown","rejected"].contains($0.status)}).map(\.id) {
            guard let index = queue.firstIndex(where:{$0.id==id}), owner == account, !Task.isCancelled else { break }
            let upload = queue[index].upload; queue[index].status = "uploading"; queue[index].message = "正在上传…"
            do {
                // 超过 4 MB 分片上传（同时 3 片、断点续传），进度写在这一行的状态里
                _ = try await session.api.uploadDataset(upload) { sent, total in
                    guard total > 0 else { return }
                    let percent = min(99, Int(Double(sent) / Double(total) * 100))
                    Task { @MainActor in if let index = queue.firstIndex(where: { $0.id == id }), queue[index].status == "uploading" { queue[index].message = "正在上传… \(percent)%" } }
                }
                guard active, owner == account else { break }; if let index = queue.firstIndex(where:{$0.id==id}) { queue[index].status = "accepted"; queue[index].message = "服务器已接受"; upload.discard() } }
            catch { guard active, owner == account, let index = queue.firstIndex(where:{$0.id==id}) else { break }; if case APIError.server(let status,let code) = error, (400..<500).contains(status) { queue[index].status = code.contains("CONFLICT") ? "conflict":"rejected"; queue[index].upload = upload.rekey(); queue[index].message = explain(error) } else { queue[index].status = "unknown"; queue[index].message = "结果尚未确认；重试沿用原标识。" } }
        }
        if owner == account {
            busy = false; await load(); refresh = UUID()
            if conflictID == nil, let first = queue.first(where:{ $0.status == "conflict" }) { conflictID = first.id }
            if queue.contains(where:{ $0.status == "selected" }) { startUpload() }
            let done = queue.filter { $0.status == "accepted" }
            if !done.isEmpty { notice = .done(done.count == 1 ? "「\(done[0].upload.name)」已上传" : "已上传 \(done.count) 个文件", "解析完成后就能在对话和求职记录里引用"); done.forEach { item in queue.removeAll { $0.id == item.id } } }
        }
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
            self.draft = nil; notice = .done("项目说明已保存")
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
            let c = Beijing.calendar.dateComponents([.month,.day,.weekday,.hour,.minute],from:date)
            return String(format:"%02d-%02d 周%@ %02d:%02d",c.month ?? 0,c.day ?? 0,["日","一","二","三","四","五","六"][(c.weekday ?? 1) - 1],c.hour ?? 0,c.minute ?? 0)
        } ?? ""
        let tail = item.text("status") == "completed" ? "已完成" : item.text("status") == "cancelled" ? "已取消" : item.text("location").nonEmptyValue ?? ["video":"视频面试","onsite":"现场","phone":"电话","other":"其他"][item.text("mode")] ?? ""
        return [item.text("stage_label"),when,tail].filter { !$0.isEmpty }.joined(separator:" · ")
    }
    private func date(_ value:String,format pattern:String = "yyyy-MM-dd") -> String { guard let date = CareerApplication.date(value) else { return "—" }; let format = Beijing.formatter(); format.dateFormat = pattern; return format.string(from:date) }
    private func explain(_ error:Error) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。" }
        if case APIError.server(_,let code) = error { return ["FOLDER_NAME_CONFLICT":"文件夹名称已存在。", "DATASET_NAME_CONFLICT":"同一文件夹已有同名文件，请选择保留两份或确认替换。", "DATASET_FILENAME_CONFLICT":"同一文件夹已有同名文件，请选择保留两份或确认替换。", "DATASET_IN_PROGRESS":"资料正在处理，暂时不能删除或替换。", "DATASET_NOT_RETRYABLE":"只有解析失败的文档可重新解析。", "DATASET_FILE_TOO_LARGE":"文件超出上传限制。", "INVALID_DATASET_NAME":"名称无效，请去除路径符号或控制字符。", "DATASET_ALREADY_LINKED":"已关联其他面试，请刷新后重试。", "FOLDER_NOT_FOUND":"文件夹已不存在，请刷新后选择。", "DATASET_NOT_FOUND":"资料已不存在或不可访问。", "ASSET_DELETE_FAILED":"原文件清理失败，请刷新确认后重试。", "DATASET_BUSY":"资料正在处理，暂时不能删除或替换。", "FOLDER_NAME_DUPLICATE":"文件夹名称已存在。", "DATASET_CONTENT_CONFLICT":"资料已更新，请刷新后重新确认替换。", "PRECONDITION_FAILED":"资料已更新，请刷新后重新确认替换。"][code] ?? "操作未完成（\(code)）。请刷新确认状态后再试。" }
        return "连接失败，结果尚未确认。请刷新或沿用原标识重试。"
    }
}

/// 空状态里的胶囊按钮（06.01）：31 高、白底 #E4E4E0 描边、13 号字。
private struct ChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(V3.sans(13)).foregroundStyle(Color(hex:0x1A1A1A)).padding(.horizontal,14).frame(height:31)
            .background(configuration.isPressed ? Color(hex:0xFBFBFA) : .white,in:Capsule()).overlay(Capsule().stroke(V3.cl))
            .opacity(enabled ? 1 : 0.5).contentShape(Capsule())
    }
}

/// 稿中常用的几种灰（10 页）：#96968F 说明灰、#6B6B66 求职卡次要字、#F3F3F1 卡片舞台、#F8F8F6 上传中行底。
private enum LibraryTone {
    static let faint = Color(hex:0x96968F)
    static let muted = Color(hex:0x6B6B66)
    static let stage = Color(hex:0xF3F3F1)
    static let row = Color(hex:0xF8F8F6)
}

/// 资料库搜索框（05.01 / 04.01）：#F4F4F2 底、圆角 8、34 / 32 高，12.5 号占位字；聚焦时白底加系统聚焦环。
private struct LibrarySearchField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat? = 200
    var height: CGFloat = 34
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing:7) {
            Image(systemName:"magnifyingglass").font(.system(size:11.5)).foregroundStyle(LibraryTone.faint)
            TextField("",text:$text).textFieldStyle(.plain)
                .font(V3.sans(12.5)).foregroundStyle(V3.txt).focused($focused).accessibilityLabel(placeholder)
                .overlay(alignment:.leading) {
                    // macOS 26 上 prompt 颜色会被 foregroundStyle 覆盖，占位字手动叠加。
                    if text.isEmpty { Text(placeholder).font(V3.sans(12.5)).foregroundStyle(LibraryTone.faint).lineLimit(1).allowsHitTesting(false) }
                }
            if !text.isEmpty {
                Button { text = "" } label:{ Image(systemName:"xmark.circle.fill").font(.system(size:11)).foregroundStyle(V3.fnt2) }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal,12).frame(width:width,height:height)
        .background(focused ? Color.white : V3.field,in:RoundedRectangle(cornerRadius:8))
        .overlay(RoundedRectangle(cornerRadius:8).stroke(focused ? Color.accentColor.opacity(0.5) : .clear,lineWidth:3).padding(-1.5))
        // 窗口打开时 AppKit 会把首个输入框设为第一响应者；设计稿里搜索框默认不聚焦，出现后撤掉这次自动聚焦。
        .task { try? await Task.sleep(for:.milliseconds(80)); if text.isEmpty { focused = false } }
    }
}

/// 添加资料菜单的一项（05.03）：图标 + 12.5 中粗标题 + 11 灰字说明，悬停 #F4F4F2 圆角 7。
private struct LibraryMenuItem: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action:action) {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:icon).font(.system(size:11,weight:.medium)).foregroundStyle(V3.txt).frame(width:14).padding(.top,2)
                VStack(alignment:.leading,spacing:3) {
                    Text(title).font(V3.sans(12.5,weight:.medium)).foregroundStyle(V3.txt)
                    Text(detail).font(V3.sans(11)).foregroundStyle(LibraryTone.faint)
                }
                Spacer(minLength:0)
            }.padding(.horizontal,12).padding(.vertical,7).frame(height:46).background(hover ? V3.field : .clear,in:RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// 上传进度条（05.03）：#ECECEA 轨道上一段蓝色往复流动（上传接口没有字节进度时的不定进度）。
private struct LibraryProgressBar: View {
    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { box in
                let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:1.4) / 1.4
                ZStack(alignment:.leading) {
                    Capsule().fill(V3.line)
                    Capsule().fill(V3.blue).frame(width:box.size.width * 0.4).offset(x:-box.size.width * 0.4 + p * box.size.width * 1.4)
                }.clipShape(Capsule())
            }
        }.accessibilityLabel("正在上传")
    }
}

/// 点状浅灰舞台（02.01 / 03.02 / 03.03）：#F4F4F1 底上 14px 间距的小圆点。
private struct LibraryDotStage: View {
    var body: some View {
        Canvas { context,size in
            for x in stride(from:7.0,through:size.width,by:14) {
                for y in stride(from:7.0,through:size.height,by:14) {
                    context.fill(Path(ellipseIn:CGRect(x:x - 0.8,y:y - 0.8,width:1.6,height:1.6)),with:.color(Color(hex:0xDCDCD8)))
                }
            }
        }.background(Color(hex:0xF4F4F1))
    }
}

/// 同名冲突 Alert（02.02）里「保留两份」的浅灰整宽按钮（与「取消」同样式，但不接 Esc）。
private struct LibraryAlertGrayStyle: ButtonStyle {
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(V3.sans(13,weight:.medium)).foregroundStyle(V3.txt)
            .frame(maxWidth:.infinity).frame(height:28)
            .background(Color.black.opacity(configuration.isPressed ? 0.1 : 0.06),in:RoundedRectangle(cornerRadius:6)).contentShape(RoundedRectangle(cornerRadius:6))
    }
}

enum LibraryTypography {
    static let registered: Void = {
        for (name,ext) in [("LibrarySerif-SemiBold","ttf")] {
            if let url = Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Library") {
                CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)
            }
        }
    }()
    /// 正文用系统字体（拉丁 SF、中文苹方），和 Web `--ui-font-sans` 在 macOS 上实际落到的 PingFang SC 一致，
    /// 有真实的中粗 / 粗体字重；随包的思源黑体只有常规一档，粗体靠模拟，屏幕上发虚，已不再使用。
    static func sans(_ size:CGFloat,weight:Font.Weight = .regular) -> Font {
        .system(size:size,weight:weight)
    }
    static func serif(_ size:CGFloat) -> Font {
        _ = registered
        return .custom("LinkResumeLibrarySerif-SemiBold",size:size)
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
