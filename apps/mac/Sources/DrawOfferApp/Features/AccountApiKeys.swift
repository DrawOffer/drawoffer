import AppKit
import DrawOfferCore
import SwiftUI

/// 账号页「API Key」分组（对照 Web `ApiKeySection`，用户端 Figma 19.19）：标题右侧蓝字「＋ 创建 Key」，
/// 每把 Key 一行 50 高（名称 | 前缀… · 权限 · 删除），组尾说明 + 「怎么配置 →」。
/// Key 原文只在创建成功的弹窗里显示一次；删除走居中确认。接口：`GET/POST /api/account/api-keys`、`DELETE /api/account/api-keys/{id}`。
struct AccountApiKeySection: View {
    @Environment(SessionStore.self) private var session
    let notify: (AccountToast) -> Void

    @State private var keys: [AccountApiKeyItem]?
    @State private var failed = false
    @State private var reload = UUID()
    @State private var creating = false
    @State private var secret: AccountApiKeySecret?
    @State private var deleting: AccountApiKeyItem?
    @State private var removing = false

    private static let guideURL = URL(string: "https://github.com/ql-link/drawoffer-mcp")
    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var full: Bool { (keys?.count ?? 0) >= AccountApiKeyItem.limit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("API Key").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                Spacer()
                if keys != nil {
                    Button { creating = true } label: {
                        HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text("创建 Key") }
                    }
                    .buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(full ? V3.fnt2 : V3.blue)
                    .disabled(full).help(full ? "最多 \(AccountApiKeyItem.limit) 把，请先删除不用的 Key" : "创建 Key")
                }
            }.frame(height: 18).padding(.bottom, 6)
            AccountHairline()
            rows
            HStack(spacing: 0) {
                Text("让 Claude、Cursor 等 AI 工具通过 MCP 读取你的简历、岗位和投递记录，最多 \(AccountApiKeyItem.limit) 把。")
                Button("怎么配置 →") { if let url = Self.guideURL { NSWorkspace.shared.open(url) } }.buttonStyle(.plain).foregroundStyle(V3.link)
            }.font(V3.sans(12)).foregroundStyle(V3.fnt).frame(minHeight: 14).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(account)|\(reload)") { await load() }
        .centeredSheet(isPresented: $creating) {
            AccountApiKeyCreateSheet(close: { creating = false }) { item, raw in
                keys = [item] + (keys ?? [])
                creating = false
                secret = AccountApiKeySecret(value: raw)
            }
        }
        .centeredSheet(item: $secret) { secret in AccountApiKeySecretSheet(value: secret.value) { self.secret = nil } }
        .centeredConfirmation(deleting.map { "删除「\($0.name)」？" } ?? "删除 API Key？",
                              isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(removing ? "删除中…" : "删除", role: .destructive) { if let key = deleting { Task { await remove(key) } } }.disabled(removing)
            Button("取消", role: .cancel) {}
        } message: { Text("删除后，正在使用这把 Key 的工具会立即无法访问。") }
    }

    @ViewBuilder private var rows: some View {
        if failed {
            HStack(spacing: 6) {
                Text("API Key 读取失败。").foregroundStyle(V3.sub)
                Button("重试") { reload = UUID() }.buttonStyle(.plain).foregroundStyle(V3.link)
                Spacer()
            }.font(V3.sans(13)).frame(height: 49).padding(.bottom, 1).overlay(alignment: .bottom) { AccountHairline() }
        } else if let keys {
            if keys.isEmpty {
                Text("还没有 API Key。").font(V3.sans(13)).foregroundStyle(V3.fnt)
                    .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading).padding(.bottom, 1).overlay(alignment: .bottom) { AccountHairline() }
            }
            ForEach(keys) { key in AccountApiKeyRow(key: key) { deleting = key } }
        } else {
            V3Loading("正在读取 API Key…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
                .padding(.bottom, 1).overlay(alignment: .bottom) { AccountHairline() }
        }
    }

    private func load() async {
        let owner = account
        guard !owner.isEmpty else { return }
        failed = false
        do {
            let value = try await session.api.careerRequest(path: "/api/account/api-keys", method: "GET", query: [:], body: nil)
            guard owner == account else { return }
            keys = (value["items"]?.items ?? []).compactMap(AccountApiKeyItem.init(json:))
        } catch is CancellationError {
        } catch {
            guard owner == account else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if keys == nil { failed = true }
        }
    }

    /// 已被删掉（API_KEY_NOT_FOUND）也按删除成功处理，与 Web 一致。
    private func remove(_ key: AccountApiKeyItem) async {
        guard !removing else { return }
        removing = true
        defer { removing = false; deleting = nil }
        do {
            _ = try await session.api.careerRequest(path: "/api/account/api-keys/\(key.id)", method: "DELETE", query: [:], body: nil)
        } catch APIError.server(_, "API_KEY_NOT_FOUND") {
        } catch {
            notify(.init(kind: .error, title: AccountApiKeyItem.errorMessage(error, fallback: "删除失败，请重试。")))
            return
        }
        keys?.removeAll { $0.id == key.id }
        notify(.init(kind: .success, title: "API Key 已删除"))
    }
}

/// 列表项（`id/name/scope/key_prefix/create_time/last_used_time`，界面只用前四项）。
struct AccountApiKeyItem: Identifiable, Equatable {
    let id: String
    let name: String
    let scope: String
    let prefix: String
    nonisolated static let limit = 5

    init?(json: JSONValue) {
        let id = json.text("id")
        guard !id.isEmpty else { return nil }
        self.id = id; name = json.text("name"); scope = json.text("scope"); prefix = json.text("key_prefix")
    }

    var scopeLabel: String { scope == "read_write" ? "读写" : "只读" }

    static func errorMessage(_ error: Error, fallback: String) -> String {
        if case APIError.server(_, let code) = error {
            if code == "API_KEY_LIMIT_REACHED" { return "最多只能保留 \(limit) 把 Key，请先删除不用的 Key。" }
            if code == "API_KEY_NOT_FOUND" { return "这把 Key 已经删除。" }
        }
        return AccountRequest.errorMessage(error, fallback: fallback)
    }
}

/// 创建成功后只显示一次的明文 Key。
struct AccountApiKeySecret: Identifiable {
    let id = UUID()
    let value: String
}

/// 一把 Key 一行：50 高、底部细线；名称 14 墨黑，前缀等宽 12 浅字，权限 13 sub，垃圾桶悬停只加深颜色（不加灰底）。
private struct AccountApiKeyRow: View {
    let key: AccountApiKeyItem
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 16) {
            Text(key.name).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(key.prefix)…").font(.system(size: 12, design: .monospaced)).foregroundStyle(V3.fnt).lineLimit(1)
            Text(key.scopeLabel).font(V3.sans(13)).foregroundStyle(V3.sub).frame(width: 28, alignment: .trailing)
            Button(action: delete) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(hover ? V3.red : V3.fnt)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }.help("删除").accessibilityLabel("删除 \(key.name)")
        }
        .frame(height: 49).padding(.bottom, 1)
        .overlay(alignment: .bottom) { AccountHairline() }
    }
}

// MARK: - 创建 API Key（520 宽）

private struct AccountApiKeyCreateSheet: View {
    @Environment(SessionStore.self) private var session
    let close: () -> Void
    let created: (AccountApiKeyItem, String) -> Void

    @State private var name = ""
    @State private var scope = "read"
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed.isEmpty && trimmed.count <= 64 }
    private let scopes = [("read", "只读", "只能读取，推荐"), ("read_write", "读写", "还能新增岗位和投递记录")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("创建 API Key").font(.system(size: 17, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 22).padding(.top, 4)
            Text("持有 Key 的工具可以读取你的简历、岗位和投递记录，请只填进你信任的工具。")
                .font(V3.sans(13)).foregroundStyle(V3.sub).lineHeight(13, 18).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 8) {
                Text("名称").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Text("用来区分用途，例如「Claude Code」").font(V3.sans(12)).foregroundStyle(V3.fnt)
            }.frame(height: 16).padding(.top, 22)
            TextField("", text: $name).textFieldStyle(.plain).font(V3.sans(13.5)).foregroundStyle(V3.txt)
                .focused($focused).disabled(saving)
                .padding(.horizontal, 12).frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 7.5).stroke(focused ? V3.txt : V3.cl))
                .onChange(of: name) { if name.count > 64 { name = String(name.prefix(64)) } }
                .onSubmit { Task { await save() } }
                .accessibilityLabel("名称")
                .padding(.top, 8)
            Text("权限").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).frame(height: 16).padding(.top, 18)
            // 单选：选中项白底 1px 墨黑细边，未选浅描边（不加灰底）
            HStack(spacing: 10) {
                ForEach(scopes, id: \.0) { option in
                    Button { scope = option.0 } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: scope == option.0 ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12)).foregroundStyle(scope == option.0 ? V3.txt : V3.fnt2).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.1).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                                Text(option.2).font(V3.sans(12)).foregroundStyle(V3.fnt)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 7.5))
                        .overlay(RoundedRectangle(cornerRadius: 7.5).stroke(scope == option.0 ? V3.txt : V3.cl))
                        .contentShape(RoundedRectangle(cornerRadius: 7.5))
                    }
                    .buttonStyle(.plain).disabled(saving)
                    .accessibilityLabel("\(option.1)：\(option.2)").accessibilityAddTraits(scope == option.0 ? .isSelected : [])
                }
            }.padding(.top, 8)
            HStack(spacing: 10) {
                Text(error ?? "").font(V3.sans(12)).foregroundStyle(V3.red).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 32)).disabled(saving)
                Button(saving ? "创建中…" : "创建") { Task { await save() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 32, width: 100))
                    .disabled(!valid || saving).keyboardShortcut(.defaultAction)
            }.padding(.top, 24)
        }
        .padding(24).frame(width: 520, alignment: .leading)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true).disabled(saving) }
        .onAppear { focused = true }
    }

    private func save() async {
        guard !saving, valid else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            let value = try await session.api.careerRequest(path: "/api/account/api-keys", method: "POST", query: [:],
                                                            body: .object(["name": .string(trimmed), "scope": .string(scope)]))
            let raw = value.text("key")
            guard let item = AccountApiKeyItem(json: value), !raw.isEmpty else { throw APIError.invalidResponse }
            created(item, raw)
        } catch { self.error = AccountApiKeyItem.errorMessage(error, fallback: "创建失败，请重试。") }
    }
}

// MARK: - API Key 已创建（560 宽，明文只显示这一次）

private struct AccountApiKeySecretSheet: View {
    let value: String
    let close: () -> Void
    @State private var copied: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("API Key 已创建").font(.system(size: 17, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 22).padding(.top, 4)
            Text("请现在复制并保存。关闭后无法再次查看完整的 Key，丢失只能删除后重新创建。")
                .font(V3.sans(13)).foregroundStyle(V3.sub).lineHeight(13, 18).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 8) {
                Image(systemName: "lock").font(.system(size: 12)).foregroundStyle(V3.fnt)
                Text(value).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(V3.txt)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("API Key")
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(V3.field, in: RoundedRectangle(cornerRadius: 7.5))
            .padding(.top, 20)
            if copied == false {
                Text("无法自动复制，请手动选中后复制。").font(V3.sans(12)).foregroundStyle(V3.red).padding(.top, 8)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(action: copy) {
                    Image(systemName: copied == true ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                    Text(copied == true ? "已复制" : "复制")
                }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 32))
                Button("完成", action: close).buttonStyle(V3ButtonStyle(kind: .dark, height: 32, width: 100)).keyboardShortcut(.defaultAction)
            }.padding(.top, 24)
        }
        .padding(24).frame(width: 560, alignment: .leading)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(value, forType: .string)
    }
}
