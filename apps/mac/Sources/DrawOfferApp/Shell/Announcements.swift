import AppKit
import DrawOfferCore
import SwiftUI

/// 公告，对齐 Web `features/announcements/AnnouncementCenter.tsx`：铃铛未读点、列表浮层（新/重要标记、
/// 读取中/失败/空态）、详情弹窗（分页点、下一条/知道了）；打开列表或自动弹出重要公告时全部标为已读。
@MainActor @Observable
final class AnnouncementCenter {
    enum Status { case idle, loading, ready, error }
    private(set) var items: [Announcement] = []
    private(set) var unreadCount = 0
    private(set) var status: Status = .idle
    private(set) var freshIDs: Set<String> = []
    var detail: (ids: [String], index: Int)?
    private var fetchedAt = Date.distantPast
    private var owner = ""

    func reset(account: String) {
        guard owner != account else { return }
        owner = account; items = []; unreadCount = 0; status = .idle; freshIDs = []; detail = nil; fetchedAt = .distantPast
    }

    /// 60 秒内的再次刷新复用上次结果（与 Web `REFRESH_INTERVAL_MS` 一致）。
    func refresh(api: any APIClient, force: Bool = false) async {
        guard !owner.isEmpty else { return }
        if !force, status == .ready, Date().timeIntervalSince(fetchedAt) < 60 { return }
        let account = owner
        status = .loading
        do {
            let list = AnnouncementList(json: try await api.careerRequest(path: "/api/announcements", method: "GET", query: [:], body: nil))
            guard account == owner else { return }
            items = list.items; unreadCount = list.unreadCount; status = .ready
        } catch {
            guard account == owner else { return }
            status = .error
        }
        fetchedAt = Date()
    }

    func markAllRead(api: any APIClient) {
        guard unreadCount > 0 else { return }
        unreadCount = 0
        items = items.map { item in
            var json: [String: JSONValue] = ["id": .string(item.id), "level": .string(item.important ? "important" : "normal"),
                "category": .string(item.category), "title": .string(item.title), "body": .string(item.body), "read": .bool(true)]
            if let date = item.publishedAt { json["publishedAt"] = .string(ISO8601DateFormatter().string(from: date)) }
            return Announcement(json: .object(json))
        }
        Task { _ = try? await api.careerRequest(path: "/api/announcements/read-all", method: "POST", query: [:], body: nil) }
    }

    func viewList(api: any APIClient) {
        freshIDs = Set(items.filter { !$0.read }.map(\.id))
        markAllRead(api: api)
    }

    /// 有未读的重要公告时自动打开详情，从重要的开始（接口已把重要排在前面），可往后翻其余未读。
    func autoOpenImportant(api: any APIClient) {
        let unread = items.filter { !$0.read }
        guard detail == nil, unread.contains(where: \.important) else { return }
        detail = (unread.map(\.id), 0)
        markAllRead(api: api)
    }
}

struct AnnouncementBell: View {
    @Environment(SessionStore.self) private var session
    @Environment(AnnouncementCenter.self) private var center
    @State private var open = false

    var body: some View {
        Button {
            if open { open = false; return }
            open = true
            Task { await center.refresh(api: session.api, force: true); center.viewList(api: session.api) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell").font(.system(size: 14)).foregroundStyle(Color(hex: 0x55554F)).frame(width: 28, height: 28)
                if center.unreadCount > 0 { Circle().fill(Color(hex: 0xE5484D)).frame(width: 7, height: 7).offset(x: -5, y: 5) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(center.unreadCount > 0 ? "公告，有未读" : "公告")
            .popover(isPresented: $open, arrowEdge: .trailing) {
                AnnouncementListView { ids, index in open = false; center.detail = (ids, index) }
            }
    }
}

private struct AnnouncementListView: View {
    @Environment(AnnouncementCenter.self) private var center
    let pick: ([String], Int) -> Void

    /// Web `.ann-popover`：360 宽；头部 18/24/4、17px 衬线标题；空态 24/24/36；列表左右 12、行间 1px 线，每条 12 内边距。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("公告").font(V3.serif(17)).fontWeight(.semibold).foregroundStyle(V3.txt)
                if !center.items.isEmpty {
                    let fresh = center.items.filter { center.freshIDs.contains($0.id) }.count
                    Text(fresh > 0 ? "\(fresh) 条新公告" : "共 \(center.items.count) 条").font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x96968F))
                }
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 4)
            if center.items.isEmpty {
                VStack(spacing: 6) {
                    switch center.status {
                    case .error:
                        Text("公告暂时无法读取")
                        Text("稍后再打开试试").font(.system(size: 12)).foregroundStyle(Color(hex: 0x96968F))
                    case .ready:
                        Image(systemName: "bell").font(.system(size: 18)).foregroundStyle(Color(hex: 0xB3B3AD)).frame(width: 22, height: 22)
                        Text("暂时没有公告")
                        Text("有新功能或服务通知时会出现在这里").font(.system(size: 12)).foregroundStyle(Color(hex: 0x96968F))
                    default:
                        Text("正在读取公告…")
                    }
                }
                .font(.system(size: 13)).foregroundStyle(V3.sub).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 36)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(center.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rectangle().fill(V3.line).frame(height: 1) }
                            Button { pick(center.items.map(\.id), index) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if center.freshIDs.contains(item.id) { Circle().fill(Color(hex: 0x3F6FD8)).frame(width: 6, height: 6).accessibilityLabel("新") }
                                        if item.important { ImportantChip() }
                                        Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 21)
                                        Spacer(minLength: 4)
                                        Text("\(item.categoryLabel) · \(item.dateText)").font(.system(size: 11)).foregroundStyle(Color(hex: 0x96968F))
                                    }
                                    Text(item.summary).font(.system(size: 13)).foregroundStyle(V3.sub).lineLimit(1).truncationMode(.tail).frame(height: 20)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(AnnouncementRowStyle(first: index == 0))
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                }.frame(maxHeight: min(480, (NSApp.mainWindow?.frame.height ?? 900) - 120))
            }
        }.frame(width: 360)
    }
}

/// `.ann-item:hover`：#F4F4F2、圆角 10；第二条起上方两角不圆，贴住分隔线。
private struct AnnouncementRowStyle: ButtonStyle {
    let first: Bool
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hover || configuration.isPressed ? V3.field : .clear,
                        in: UnevenRoundedRectangle(topLeadingRadius: first ? 10 : 0, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: first ? 10 : 0))
            .onHover { hover = $0 }
    }
}

private struct ImportantChip: View {
    var body: some View {
        Text("重要").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: 0xA13A28))
            .padding(.horizontal, 6).frame(height: 18).background(Color(hex: 0xFAEDEA), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 详情弹窗：分类带、标题与 Markdown 正文；多条时显示分页点，最后一条为“知道了”。
struct AnnouncementDetailSheet: View {
    @Environment(AnnouncementCenter.self) private var center

    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: center.items.map { ($0.id, $0) })
        let ids = (center.detail?.ids ?? []).filter { byID[$0] != nil }
        let currentID = center.detail.flatMap { $0.ids.indices.contains($0.index) ? $0.ids[$0.index] : nil }
        let index = currentID.flatMap { ids.firstIndex(of: $0) } ?? -1
        if let currentID, let item = byID[currentID] {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: item.categorySymbol).font(.system(size: 18)).frame(width: 40, height: 40)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) { Text(item.categoryLabel).font(.system(size: 13, weight: .medium)); if item.important { ImportantChip() } }
                        if !item.dateText.isEmpty { Text("\(item.dateText)发布").font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x6F6F69)) }
                    }
                    Spacer()
                    Button { center.detail = nil } label: { Image(systemName: "xmark").font(.system(size: 13)) }
                        .buttonStyle(.plain).accessibilityLabel("关闭")
                }.padding(20).background(Color(hex: 0xEEF3FC))
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.custom("Songti SC", size: 20).weight(.semibold))
                    ScrollView { NativeMarkdownView(source: item.body).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 320)
                }.padding(20)
                HStack {
                    if ids.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(Array(ids.enumerated()), id: \.element) { position, id in
                                Button { goTo(position, ids: ids) } label: {
                                    Circle().fill(position == index ? Color(hex: 0x17191C) : Color(hex: 0xD4D4CF)).frame(width: 7, height: 7)
                                }.buttonStyle(.plain).accessibilityLabel("第 \(position + 1) 条，共 \(ids.count) 条")
                            }
                        }
                    }
                    Spacer()
                    if index < ids.count - 1 {
                        Button { goTo(index + 1, ids: ids) } label: { Label("下一条", systemImage: "arrow.right").labelStyle(.titleAndIcon) }
                            .buttonStyle(WebActionStyle()).keyboardShortcut(.defaultAction)
                    } else {
                        Button("知道了") { center.detail = nil }.buttonStyle(WebActionStyle()).keyboardShortcut(.defaultAction)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }.frame(width: 520)
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { center.detail = nil }
        }
    }

    private func goTo(_ position: Int, ids: [String]) {
        guard let detail = center.detail, ids.indices.contains(position), let target = detail.ids.firstIndex(of: ids[position]) else { return }
        center.detail = (detail.ids, target)
    }
}

/// “我的额度”弹窗占位：套餐、积分明细与邀请好友在 M11 补齐。
struct PlansSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("我的额度").font(.headline)
            Button("知道了") { dismiss() }
        }.padding(24).frame(width: 360)
    }
}
