import AppKit
import DrawOfferCore
import SwiftUI

/// 会员与积分（macOS 稿 01 页「06 · 会员与积分弹窗」）：900×822、四个标签同高的弹窗。
/// 06.01 会员方案（定稿：插画与「≈ 多少钱」并排、方案名 20）、06.04 积分充值同款、06.05 积分明细、06.09 邀请好友。
/// 方案由后端 `GET /api/agent/cards/plans` 描述（分组即标签：membership / pack），后面接客户端自己的「积分明细」「邀请好友」。
/// 付款在浏览器的支付宝页面完成，这里轮询票据直到有结果。
struct PlansSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.closeModal) private var dismiss
    /// 打开时停在哪个标签：后端分组 id（membership / pack）或 "credits" / "invite"；nil 为第一个分组。
    var initialTab: String? = nil
    @State private var card: JSONValue?
    @State private var status = "loading"
    @State private var retry = 0
    @State private var group: String?
    @State private var extra: String?
    @State private var picks: [String: String] = [:]
    @State private var busy: String?
    @State private var error: String?
    @State private var opened: (ticket: String, url: URL?)?
    @State private var ticket: JSONValue?
    @State private var inviteText = ""
    @State private var invite: JSONValue?
    @State private var inviteError: String?
    @State private var checking = false
    @State private var appliedInitial = false
    @State private var qrOpen = false

    private var groups: [JSONValue] { card?["groups"]?.items ?? [] }
    private var activeGroup: JSONValue? { groups.first { $0.text("id") == group } ?? groups.first }
    private var items: [JSONValue] {
        let all = card?["items"]?.items ?? []
        guard let active = activeGroup, groups.count > 1 else { return all }
        return all.filter { $0.text("group") == active.text("id") }
    }
    private var buyable: [JSONValue] { items.filter { $0["action"] != nil && $0["action"] != .null } }
    private var pickKey: String { activeGroup?.text("id") ?? "__items" }
    private var selected: JSONValue? { buyable.first { $0.text("id") == picks[pickKey] } ?? buyable.first { $0["featured"]?.bool == true } ?? buyable.first }
    private var phase: String { opened == nil ? "idle" : ticket.map { $0.text("state") == "pending" ? "waiting" : $0.text("state") } ?? "waiting" }
    private var locked: Bool { opened != nil && (phase == "waiting") }
    /// 06.04 积分充值：三张卡矮一些（423），弹窗 779 高；其余标签 822。
    private var isPack: Bool { extra == nil && activeGroup?.text("id") == "pack" }
    private var sheetHeight: CGFloat { isPack ? 779 : 822 }
    private var notes: [String] { (activeGroup?["notes"]?.items ?? []).compactMap(\.stringValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if let card { content(card) } else { stateView }
        }
        .padding(.horizontal, 33).padding(.top, 43).padding(.bottom, 36)
        .frame(width: 900, height: sheetHeight, alignment: .topLeading)
        .overlay { qrLayer }
        .task(id: retry) { await load() }
        .task(id: opened?.ticket ?? "") { await poll() }
        .onAppear {
            guard !appliedInitial else { return }
            appliedInitial = true
            if initialTab == "credits" || initialTab == "invite" { extra = initialTab } else { group = initialTab }
        }
    }

    /// 标题 28 宋体，右侧「当前：免费版」14/500 + 关闭 ×。
    private var head: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(card?.text("title").nonEmptyValue ?? "会员与积分").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 40)
            Spacer(minLength: 0)
            // 会员等级与关闭：与标题不同高，整体比标题中线高 4（设计稿 32 高的容器），关闭 ✕ 10×10 距右缘 11
            HStack(alignment: .center, spacing: 24) {
                if let card { Text(card.text("status")).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1) }
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .regular)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.sub).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").offset(x: -4)
            }.offset(y: -4)
        }
    }

    /// 06.13 客服微信二维码：整张弹窗盖一层 28% 的深色遮罩，二维码卡居中（Esc / 点遮罩 / ✕ 关闭）。
    @ViewBuilder private var qrLayer: some View {
        if qrOpen {
            ZStack {
                Color(red: 20 / 255, green: 20 / 255, blue: 18 / 255).opacity(0.28).onTapGesture { qrOpen = false }
                SupportQR(api: session.api) { qrOpen = false }
            }.clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var stateView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if status == "loading" { V3Loading("正在加载方案…", retry: { retry += 1 }).font(V3.sans(13)) }
            else {
                Text(status == "error" ? "暂时无法读取方案，请重试。" : "暂无可用方案").font(V3.sans(14)).foregroundStyle(V3.sub)
                Button("重试") { retry += 1 }.buttonStyle(V3ButtonStyle(kind: .ghost))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(_ card: JSONValue) -> some View {
        tabs(card)
        switch extra {
        case "credits": CreditsPanel().frame(maxHeight: .infinity, alignment: .top)
        case "invite": InvitePanel(qrOpen: $qrOpen).frame(maxHeight: .infinity, alignment: .top)
        default: plans(card)
        }
        if let error { Text(error).font(V3.sans(13)).foregroundStyle(V3.red).padding(.top, 10) }
    }

    /// 标签：96 宽、间距 12，14/500，选中墨黑 + 2px 下划线；积分明细 / 邀请好友时右侧放「会员与积分说明 ↗」。
    private func tabs(_ card: JSONValue) -> some View {
        let tabGroups = groups.isEmpty ? [("__items", "方案")] : groups.map { ($0.text("id"), $0.text("label")) }
        return HStack(alignment: .top, spacing: 12) {
            ForEach(tabGroups, id: \.0) { item in tab(item.1, active: extra == nil && (item.0 == activeGroup?.text("id") || item.0 == "__items")) { group = item.0; extra = nil } }
            tab("积分明细", active: extra == "credits") { extra = "credits" }
            tab("邀请好友", active: extra == "invite") { extra = "invite" }
            Spacer(minLength: 0)
            if extra != nil { explainLink.frame(height: 17) }
        }.frame(height: 44).padding(.top, 33)
    }

    private var explainLink: some View {
        Button { WebBridge.open("/pricing/credits", api: session.api) } label: {
            HStack(spacing: 3) { Text("会员与积分说明"); Text("↗").font(.system(size: 12)) }
        }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.sub)
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(active ? V3.txt : V3.sub).frame(width: 96, height: 44, alignment: .top)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(V3.txt).frame(height: 2).offset(y: -15) } }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder private func plans(_ card: JSONValue) -> some View {
        // 额度说明一行（12 sub）+ 问号说明 + 右侧「会员与积分说明 ↗」
        HStack(spacing: 6) {
            if !card.text("text").isEmpty { Text(card.text("text")).font(V3.sans(12)).foregroundStyle(V3.sub).lineLimit(1) }
            if !notes.isEmpty {
                // 免费版说明：13 的细圈 + 9/500 的「?」（#55554F）
                Text("?").font(V3.sans(9, weight: .medium)).foregroundStyle(V3.sub).frame(width: 13, height: 13)
                    .overlay(Circle().stroke(V3.sub, lineWidth: 1)).help(notes.joined(separator: "\n"))
                    .accessibilityLabel(notes.joined(separator: "，"))
            }
            Spacer(minLength: 12)
            explainLink
        }.frame(height: 16).padding(.top, 13)
        HStack(alignment: .top, spacing: 17) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in planCard(item) }
        }.frame(height: isPack ? 423 : 466).padding(.top, 32)
        Spacer(minLength: 0)
        if let selected, let action = selected["action"], action != .null { checkout(card, selected, action) }
    }

    /// 方案卡：266 宽、圆角 15.5、#EAEAE6 描边（选中 1.5 墨黑）；内边距 26。
    /// 方案名 20/500 + 描边小徽标 → 副标题 12.5 → 价格 38（Inter）+ 周期 → 划线原价 + 「限时 N 折」
    /// → 72 插画与「≈ 多少钱」并排 → 细线 → 积分 14/500 → 权益列表（灰勾 13）。
    private func planCard(_ item: JSONValue) -> some View {
        let selectable = item["action"] != nil && item["action"] != .null
        let on = selectable && item.text("id") == selected?.text("id")
        let dimmed = locked && !on || busy != nil && !on
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(item.text("title")).font(V3.sans(20, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                if !item.text("badge").isEmpty {
                    Text(item.text("badge")).font(V3.sans(11)).foregroundStyle(Color(hex: 0x8F8F89)).padding(.horizontal, 7).frame(height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(Color(hex: 0xD6D6D1)))
                }
            }.frame(height: 24)
            Text(item.text("subline").nonEmptyValue ?? " ").font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8F8F89)).lineLimit(1).frame(height: 15).padding(.top, 4)
            if !item.text("price").isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.text("price")).font(.system(size: 38, weight: .medium)).foregroundStyle(V3.txt)
                    if !item.text("period").isEmpty { Text(item.text("period")).font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8F8F89)) }
                }.frame(height: 46).padding(.top, 33)
                // 积分包没有原价 / 折扣行（06.04）：插画直接接在价格下面（间距 15），否则隔一行 20 + 14
                let hasOriginal = !item.text("original").isEmpty || !item.text("offTag").isEmpty
                if hasOriginal {
                    HStack(spacing: 8) {
                        if !item.text("original").isEmpty { Text(item.text("original")).font(.system(size: 12.5)).strikethrough().foregroundStyle(Color(hex: 0xB0B0AA)) }
                        if !item.text("offTag").isEmpty { Text(item.text("offTag")).font(V3.sans(12)).foregroundStyle(Color(hex: 0xC0532B)) }
                    }.frame(height: 15).padding(.top, 5)
                }
                if let analogy = item["analogy"], analogy != .null {
                    HStack(spacing: 12) {
                        AccountBillingArt(name: analogy.text("icon"), size: 72)
                        Text(analogy.text("text")).font(V3.sans(14, weight: .medium)).foregroundStyle(Color(hex: 0x8A5E36)).lineLimit(1)
                    }.frame(height: 72).padding(.top, hasOriginal ? 14 : 15)
                } else { Color.clear.frame(height: hasOriginal ? 86 : 87) }
            }
            Rectangle().fill(Color(hex: 0xF0F0EC)).frame(height: 1).padding(.top, 24)
            if !item.text("headline").isEmpty {
                Text(item.text("headline")).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(height: 17).padding(.top, 22)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array((item["lines"]?.items ?? []).compactMap(\.stringValue).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xA8A8A2)).frame(width: 14, height: 16)
                        Text(line).font(V3.sans(13)).foregroundStyle(Color(hex: 0x4A4A46)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.top, 14)
            if !item.text("note").isEmpty { Text(item.text("note")).font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.top, 12).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 15.5))
        .overlay(RoundedRectangle(cornerRadius: 15.5).stroke(on ? V3.txt : Color(hex: 0xEAEAE6), lineWidth: on ? 1.5 : 1))
        .opacity(dimmed ? 0.55 : selectable ? 1 : 0.7).contentShape(RoundedRectangle(cornerRadius: 15.5))
        .onTapGesture { if selectable && !locked && busy == nil { picks[pickKey] = item.text("id") } }
        .accessibilityElement(children: .combine).accessibilityAddTraits(on ? [.isSelected, .isButton] : selectable ? .isButton : [])
    }

    /// 结算行：上边线；左侧邀请码 / 付款进度，右侧「应付 ~~原价~~ 现价」与说明，最右唯一的墨黑胶囊（140×48）。
    private func checkout(_ card: JSONValue, _ selected: JSONValue, _ action: JSONValue) -> some View {
        let inviteHere = card["invite"].flatMap { inv in inv != .null && buyable.contains { $0.text("group") == inv.text("group") } ? inv : nil }
        let priced = invite?["prices"]?[action.text("id")]
        let original = phase == "idle" ? (priced?.text("original").nonEmptyValue ?? (action.text("amount") == selected.text("price") ? selected.text("original").nonEmptyValue : nil)) : nil
        return HStack(spacing: 16) {
            Group {
                if phase == "idle" {
                    if let inviteHere {
                        if selected.text("group") == inviteHere.text("group") { coupon(inviteHere) }
                        else { Text("积分包长期有效，不使用邀请码").font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
                    } else { Color.clear.frame(height: 1) }
                } else { payStatus }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if ["idle", "waiting", "closed"].contains(phase) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("应付").font(V3.sans(13)).foregroundStyle(V3.sub)
                        if let original { Text(original).font(.system(size: 13)).strikethrough().foregroundStyle(Color(hex: 0xB0B0AA)) }
                        Text((phase == "idle" ? priced?.text("price").nonEmptyValue : nil) ?? action.text("amount").nonEmptyValue ?? selected.text("price"))
                            .font(.system(size: 26, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 31)
                    }
                    if !action.text("caption").isEmpty { Text(action.text("caption")).font(V3.sans(11.5)).foregroundStyle(Color(hex: 0x9A9A94)) }
                }
            }
            Group {
                switch phase {
                case "waiting": Button("等待付款结果") {}.buttonStyle(CheckoutStyle()).disabled(true)
                case "done": Button("知道了") { Task { await finish() } }.buttonStyle(CheckoutStyle())
                case "review", "refunded": Button("知道了") { Task { await finish() } }.buttonStyle(CheckoutStyle(ghost: true))
                default: Button(busy == action.text("id") ? "正在处理…" : action.text("label")) { Task { await run(action.text("id")) } }.buttonStyle(CheckoutStyle()).disabled(busy != nil)
                }
            }
        }.padding(.top, 24).overlay(alignment: .top) { Rectangle().fill(V3.cl).frame(height: 1) }.padding(.top, 24)
    }

    /// 邀请码：339×47、圆角 11.5、#E3E3DF 描边的白框，灰色券图标 + 「填好友邀请码，立减 ¥5」+ 浅灰「使用」；核对成功后变成已减提示。
    @ViewBuilder private func coupon(_ config: JSONValue) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11.5)
        if let invite {
            // 06.02 已使用：白底同款描边；「邀请码 已减 ¥5」都是 13.5/500 墨黑，右侧 54×36 的「移除」
            HStack(spacing: 10) {
                Image(systemName: "ticket").font(.system(size: 15)).foregroundStyle(Color(hex: 0x8D8D87))
                HStack(spacing: 7) {
                    Text(invite.text("code")).font(.system(size: 13.5, weight: .medium))
                    Text("已减 \(invite.text("discount"))").font(V3.sans(13.5, weight: .medium))
                }.foregroundStyle(V3.txt).frame(maxWidth: .infinity, alignment: .leading)
                Button("移除") { self.invite = nil; inviteText = ""; inviteError = nil }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    .padding(.horizontal, 14).frame(height: 36).background(Color(hex: 0xF2F2EF), in: RoundedRectangle(cornerRadius: 8)).disabled(busy != nil)
            }.padding(.leading, 14).padding(.trailing, 6).frame(width: 339, height: 47)
                .background(Color.white, in: shape).overlay(shape.stroke(Color(hex: 0xE3E3DF)))
        } else {
            HStack(spacing: 10) {
                Image(systemName: "ticket").font(.system(size: 15)).foregroundStyle(Color(hex: 0x8D8D87))
                ZStack(alignment: .leading) {
                    if inviteText.isEmpty {
                        (Text(config.text("label")) + Text(config.text("entry").isEmpty ? "" : "，") + Text(config.text("entry")).foregroundColor(V3.txt).fontWeight(.medium))
                            .font(V3.sans(13.5)).foregroundStyle(Color(hex: 0x8D8D87)).lineLimit(1).allowsHitTesting(false)
                    }
                    TextField("", text: $inviteText).textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).tracking(0.8).accessibilityLabel(config.text("label"))
                        .onChange(of: inviteText) { inviteText = String(inviteText.uppercased().prefix(32)); inviteError = nil }
                        .onSubmit { Task { await checkInvite() } }
                }
                Button(checking ? "核对中…" : "使用") { Task { await checkInvite() } }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    .padding(.horizontal, 14).frame(height: 36).background(Color(hex: 0xF2F2EF), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(checking || inviteText.trimmingCharacters(in: .whitespaces).isEmpty).opacity(checking || inviteText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.55 : 1)
            }.padding(.leading, 14).padding(.trailing, 6).frame(width: 339, height: 47)
                .background(Color.white, in: shape).overlay(shape.stroke(Color(hex: 0xE3E3DF)))
                .overlay(alignment: .bottomLeading) { if let inviteError { Text(inviteError).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize().offset(x: 2, y: 20) } }
        }
    }

    /// 付款进度：等待中可重新打开支付宝页；结束后显示后端给的结果文字。
    private var payStatus: some View {
        let tone = phase == "waiting" ? "wait" : phase == "done" ? "ok" : phase == "closed" ? "info" : "warn"
        let colors: [String: (Color, Color)] = ["wait": (V3.field, V3.txt), "ok": (V3.greenSoft, Color(hex: 0x2F7D4F)),
                                                "info": (V3.field, V3.sub), "warn": (V3.orangeSoft, Color(hex: 0xC9781A))]
        return HStack(spacing: 12) {
            Image(systemName: tone == "wait" ? "arrow.triangle.2.circlepath" : tone == "ok" ? "checkmark" : tone == "info" ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 15)).foregroundStyle(colors[tone]!.1).frame(width: 36, height: 36).background(colors[tone]!.0, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(phase == "waiting" ? "请在新打开的支付宝页面完成付款" : ticket?.text("text") ?? "").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                if phase == "waiting" {
                    HStack(spacing: 10) {
                        Text("订单 15 分钟内有效，付款后这里会自动更新").foregroundStyle(V3.sub)
                        Button("重新打开") { if let url = opened?.url { NSWorkspace.shared.open(url) } }.buttonStyle(.plain).foregroundStyle(V3.blue).fontWeight(.medium)
                    }.font(V3.sans(12.5))
                }
            }
        }
    }

    // MARK: 动作

    private func request(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: method, query: [:], body: body)
    }

    private func load() async {
        status = "loading"
        do {
            let next = try await request("/api/agent/cards/plans")["card"]
            card = next == .null ? nil : next
            status = card == nil ? "empty" : "ready"
        } catch { status = "error" }
    }

    private func reason(_ error: Error) -> String { "暂时无法处理，请稍后再试。" }

    private func checkInvite() async {
        let code = inviteText.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        inviteError = nil; checking = true
        defer { checking = false }
        do { invite = try await request("/api/billing/invite-codes/check", method: "POST", body: .object(["code": .string(code)])) }
        catch { invite = nil; inviteError = "邀请码不可用，请检查后重试。" }
    }

    /// 下单后在默认浏览器打开支付宝付款页，然后轮询票据。
    private func run(_ actionID: String) async {
        error = nil; busy = actionID
        defer { busy = nil }
        do {
            var body: [String: JSONValue] = ["idempotency_key": .string(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))]
            if let invite, invite["prices"]?[actionID] != nil { body["invite_code"] = .string(invite.text("code")) }
            let result = try await request("/api/agent/actions/\(actionID)", method: "POST", body: .object(body))
            let url = URL(string: result.text("open_url")).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
            if let url { NSWorkspace.shared.open(url) }
            ticket = nil
            opened = (result.text("ticket"), url)
        } catch { self.error = reason(error) }
    }

    private func poll() async {
        guard let id = opened?.ticket, !id.isEmpty else { return }
        let started = Date()
        while !Task.isCancelled, Date().timeIntervalSince(started) < 30 * 60 {
            if let next = try? await request("/api/agent/tickets/\(id)") {
                ticket = next
                if next.text("state") != "pending" { return }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func finish() async {
        let done = phase == "done"
        opened = nil; ticket = nil
        guard done else { return }
        if let next = try? await request("/api/agent/cards/plans")["card"], next != .null { card = next }
    }
}

/// 结算主按钮：墨黑胶囊 48 高（macOS 稿：主按钮墨黑胶囊）；ghost 为白底细边。
private struct CheckoutStyle: ButtonStyle {
    var ghost = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14, weight: .medium)).foregroundStyle(ghost ? V3.txt : .white).padding(.horizontal, 26).frame(minWidth: 140, minHeight: 48)
            .background(ghost ? Color.white : configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt, in: Capsule())
            .overlay(Capsule().stroke(ghost ? Color.black.opacity(0.1) : .clear)).opacity(enabled ? 1 : 0.45).contentShape(Capsule())
    }
}

/// 计费插画（Web `assistant/assets/billing-art`，手绘墨线 + 暖色）：tea / chicken / hotpot / sweet / coffee / film / coin-jar / paper-plane / red-envelope。
struct AccountBillingArt: View {
    let name: String
    var size: CGFloat = 56
    var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: name, withExtension: "webp", subdirectory: "Branding/AccountBillingArt"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Color.clear }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

// MARK: - 06.05 积分明细（数字统一 Inter、细进度条、收入墨绿）

private struct CreditsPanel: View {
    @Environment(SessionStore.self) private var session
    @State private var summary: JSONValue?
    @State private var direction = "all"
    @State private var rows: [JSONValue]?
    @State private var month: JSONValue?
    @State private var cursor: String?
    @State private var loadingMore = false
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("暂时无法读取积分明细，请重试。").font(V3.sans(14)).foregroundStyle(V3.sub)
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            } else if let summary { VStack(alignment: .leading, spacing: 0) { panel(summary) }.frame(maxHeight: .infinity, alignment: .top) }
            else { Text("正在加载…").font(V3.sans(14)).foregroundStyle(V3.sub) }
        }.padding(.top, 9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: direction) { await load() }
    }

    private func number(_ value: JSONValue?) -> Double { value?.numberValue ?? Double(value?.stringValue ?? "") ?? 0 }

    @ViewBuilder private func panel(_ summary: JSONValue) -> some View {
        let balances = summary["balances"] ?? .null
        let member = summary.text("tier") != "none"
        let extra = number(balances["pack"]?["remaining"]) + number(balances["gift"]?["remaining"])
        let periodTotal = member ? number(balances["membership"]?["total"] ?? balances["membership"]?["remaining"]) : number(balances["freeMonthly"]?["total"])
        let periodLeft = member ? number(balances["membership"]?["remaining"]) : number(balances["freeMonthly"]?["remaining"])
        let used = max(0, periodTotal - periodLeft), total = periodTotal + extra
        let share = total > 0 ? min(1, used / total) : 0, percent = Int((share * 100).rounded()), warn = share >= 0.8
        let reset = member
            ? (balances["membership"]?.text("expireTime")).flatMap { $0.isEmpty ? nil : "\(monthDay($0))到期，未用完的清零" } ?? ""
            : "\(monthDay(balances["freeMonthly"]?.text("resetTime") ?? ""))重置为 \(BillingSummary.credits(balances["freeMonthly"]?.display("total") ?? ""))"
        // 06.07 会员 / 06.08 免费用户：一根 10 高的用量条，数字 40/600，下面一条 #E8E8E2 分隔线
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member ? "会员积分" : "本月免费积分").font(V3.sans(13)).foregroundStyle(Color(hex: 0x62625D)).frame(height: 16)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(BillingSummary.credits(summary.display("available"))).font(.system(size: 40, weight: .semibold)).foregroundStyle(Color(hex: 0x1B1B19)).frame(height: 48)
                        Text("积分可用").font(V3.sans(14)).foregroundStyle(Color(hex: 0x62625D))
                    }
                }
                Spacer()
                Text("已用 \(percent)%").font(V3.sans(14, weight: .medium)).foregroundStyle(warn ? Color(hex: 0xD47C28) : Color(hex: 0x1B1B19)).frame(height: 17)
            }
            GeometryReader { geometry in
                Capsule().fill(Color(hex: 0xEEEEEA)).overlay(alignment: .leading) {
                    Capsule().fill(warn ? Color(hex: 0xD47C28) : Color(hex: 0x2B2B28)).frame(width: max(10, geometry.size.width * share))
                }
            }.frame(height: 10).padding(.top, 16).accessibilityLabel("已用积分").accessibilityValue("\(percent)%")
            HStack {
                Text("\(member ? "本期" : "本月")已用 \(BillingSummary.credits(String(used))) / \(BillingSummary.credits(String(total)))")
                Spacer()
                Text(reset)
            }.font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x62625D)).frame(height: 15).padding(.top, 14)
            if number(summary["overdraft"]) > 0 { Text("含透支 \(BillingSummary.credits(summary.display("overdraft"))) 积分，下次获得积分时先抵扣").font(V3.sans(12)).foregroundStyle(Color(hex: 0x9A9A94)).frame(height: 14).padding(.top, 14) }
            else if !member && extra == 0 { Text("免费积分只能用基础模型；开通会员可用全部模型").font(V3.sans(12)).foregroundStyle(Color(hex: 0x9A9A94)).frame(height: 14).padding(.top, 14) }
        }.padding(.bottom, 24).overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xE8E8E2)).frame(height: 1) }
        HStack(spacing: 16) {
            Text("积分变动").font(V3.sans(15, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19)).frame(height: 18)
            HStack(spacing: 4) {
                ForEach([("all", "全部"), ("use", "使用"), ("gain", "获得")], id: \.0) { item in
                    Button(item.1) { direction = item.0 }.buttonStyle(.plain).font(V3.sans(12.5, weight: direction == item.0 ? .medium : .regular))
                        .foregroundStyle(direction == item.0 ? Color(hex: 0x1B1B19) : Color(hex: 0x9A9A94)).padding(.horizontal, 5).frame(height: 26)
                        .accessibilityAddTraits(direction == item.0 ? .isSelected : [])
                }
            }
            Spacer()
            if let month {
                Text(member ? "本期已用 \(BillingSummary.credits(month.display("used"))) · 获得 \(BillingSummary.credits(month.display("gained")))" : "本月已用 \(BillingSummary.credits(month.display("used")))")
                    .font(V3.sans(12)).foregroundStyle(Color(hex: 0x9A9A94))
            }
        }.padding(.top, 20).padding(.bottom, 1)
        if let rows {
            if rows.isEmpty { Text("还没有积分变动。").font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.vertical, 12) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in ledgerRow(row, first: index == 0) }
                        if cursor != nil {
                            Button(loadingMore ? "正在加载…" : "加载更早的记录") { Task { await more() } }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.sub)
                                .disabled(loadingMore).padding(.top, 10)
                        }
                    }
                }.scrollIndicators(.never).frame(maxHeight: .infinity, alignment: .top)
            }
        } else { Text("正在加载…").font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.vertical, 12) }
    }

    private func ledgerRow(_ row: JSONValue, first: Bool) -> some View {
        let points = number(row["points"]), muted = ["expire", "void"].contains(row.text("entryType"))
        return HStack(spacing: 16) {
            Text(row.text("title")).font(V3.sans(14)).foregroundStyle(muted ? V3.fnt : Color(hex: 0x1B1B19)).lineLimit(1).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            Text(stamp(row.text("occurTime"))).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Color(hex: 0x9A9A94))
            Text(points > 0 ? "+" + BillingSummary.credits(row.display("points")) : BillingSummary.credits(row.display("points")).replacingOccurrences(of: "-", with: "−"))
                .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(muted ? V3.fnt : points > 0 ? Color(hex: 0x2F9A5B) : Color(hex: 0x1B1B19)).frame(width: 72, alignment: .trailing)
        }.padding(.vertical, 10).overlay(alignment: .top) { if !first { Rectangle().fill(Color(hex: 0xE8E8E2)).frame(height: 1) } }
    }

    private func monthDay(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let parts = Beijing.calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    }

    /// 「今天 15:30」或「10-26 15:30」。
    private func stamp(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let format = Beijing.formatter()
        format.dateFormat = "HH:mm"
        if Beijing.calendar.isDateInToday(date) { return "今天 " + format.string(from: date) }
        format.dateFormat = "MM-dd HH:mm"
        return format.string(from: date)
    }

    private func page(_ cursor: String?) async throws -> JSONValue {
        var query = ["limit": "20"]
        if let cursor { query["cursor"] = cursor }
        if direction != "all" { query["direction"] = direction }
        return try await session.api.careerRequest(path: "/api/billing/ledger", method: "GET", query: query, body: nil)
    }

    private func load() async {
        rows = nil; failed = false
        do {
            async let summaryTask = session.api.careerRequest(path: "/api/billing/summary", method: "GET", query: [:], body: nil)
            async let pageTask = page(nil)
            let (s, p) = try await (summaryTask, pageTask)
            summary = s; rows = p["items"]?.items ?? []; cursor = p.text("nextCursor").nonEmptyValue
            if let m = p["month"], m != .null { month = m }
        } catch { failed = true }
    }

    private func more() async {
        guard let cursor else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let p = try? await page(cursor) else { return }
        rows = (rows ?? []) + (p["items"]?.items ?? []); self.cursor = p.text("nextCursor").nonEmptyValue
    }
}

// MARK: - 06.09 邀请好友（单色 + 红包插画，蓝色换墨黑 / 暖纸）

private struct InvitePanel: View {
    @Environment(SessionStore.self) private var session
    @Binding var qrOpen: Bool
    @State private var mine: JSONValue?
    @State private var records: [JSONValue] = []
    @State private var failed = false
    @State private var copied: String?

    var body: some View {
        Group {
            if failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("暂时无法读取邀请信息，请重试。").font(V3.sans(14)).foregroundStyle(V3.sub)
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            } else if let mine { panel(mine) }
            else { Text("正在加载…").font(V3.sans(14)).foregroundStyle(V3.sub) }
        }.padding(.top, 1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await load() }
    }

    private func yuan(_ value: String) -> String { String(format: "¥%.2f", Double(value) ?? 0) }
    private func amount(_ value: String) -> String { let number = Double(value) ?? 0; return number == number.rounded() ? "\(Int(number))" : String(number) }

    /// 06.09：上排邀请券（暖纸底 + 红包插画）与返现说明并排，下面是邀请记录卡。
    @ViewBuilder private func panel(_ mine: JSONValue) -> some View {
        let rewards = mine["rewards"]?.items ?? []
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 17) {
                coupon(mine).frame(width: 400)
                VStack(alignment: .leading, spacing: 0) {
                    Text("好友每开通一次会员，你得到现金返现").font(V3.sans(13, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19)).frame(height: 16)
                    HStack(spacing: 0) {
                        ForEach(Array(rewards.enumerated()), id: \.offset) { index, row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.text("title")).font(V3.sans(12)).foregroundStyle(Color(hex: 0x62625D)).frame(height: 14)
                                Text(row.text("reward")).font(.system(size: 26, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 31)
                                Text("好友付 \(row.text("price"))").font(V3.sans(11.5)).foregroundStyle(Color(hex: 0x9A9A94)).frame(height: 14).padding(.top, 2)
                            }.padding(.leading, index > 0 ? 17 : 0).frame(width: index > 0 ? 128.3 : 111.4, alignment: .leading)
                                .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(Color(hex: 0xECECE8)).frame(width: 1) } }
                        }
                    }.padding(.top, 22)
                    Spacer(minLength: 10)
                    Text("返现按好友实际付款计算，核实后用微信或支付宝转给你").font(V3.sans(11.5)).foregroundStyle(Color(hex: 0x9A9A94)).frame(height: 14)
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 21).frame(maxWidth: .infinity, alignment: .leading).frame(height: 183)
                    .overlay(RoundedRectangle(cornerRadius: 15.5).stroke(Color(hex: 0xECECE8)))
            }
            ledger(mine, rewards).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// 邀请券：400×184、#F6F3EC 暖纸底、圆角 16；左栏红包插画 + 「立减 ¥5」，虚线隔开，右栏邀请码与两个复制按钮；虚线两端各一个缺口。
    private func coupon(_ mine: JSONValue) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                AccountBillingArt(name: "red-envelope", size: 56)
                Text("好友开通会员").font(V3.sans(12)).foregroundStyle(Color(hex: 0x8F8F89)).frame(height: 14).padding(.top, 8)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("立减").font(V3.sans(14, weight: .medium))
                    Text("¥\(amount(mine.text("discountAmount")))").font(.system(size: 44, weight: .semibold))
                }.foregroundStyle(V3.txt).frame(height: 53).padding(.top, 7)
            }.frame(width: 136).frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Rectangle().stroke(Color(hex: 0xCFC8B8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: 1).padding(.vertical, 18) }
            VStack(alignment: .leading, spacing: 0) {
                Text("我的邀请码").font(V3.sans(12)).foregroundStyle(Color(hex: 0x62625D)).frame(height: 14)
                Text(mine.text("code")).font(.system(size: 30, weight: .semibold)).tracking(2).foregroundStyle(Color(hex: 0x1B1B19)).frame(height: 36).padding(.top, 5)
                HStack(spacing: 8) {
                    Button(copied == "code" ? "已复制" : "复制邀请码") { copy("code", mine) }
                        .buttonStyle(.borderedProminent).tint(Color(hex: 0x1B1B19)).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 8)).font(V3.sans(12.5, weight: .medium))
                    Button(copied == "text" ? "已复制" : "复制邀请文案") { copy("text", mine) }.buttonStyle(AccountInviteButtonStyle())
                }.padding(.top, 17)
            }.padding(.leading, 24).padding(.trailing, 16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 184).background(Color(hex: 0xF6F3EC))
        .mask {
            Rectangle().overlay(alignment: .topLeading) { Circle().frame(width: 22, height: 22).offset(x: 125, y: -11).blendMode(.destinationOut) }
                .overlay(alignment: .bottomLeading) { Circle().frame(width: 22, height: 22).offset(x: 125, y: 11).blendMode(.destinationOut) }.compositingGroup()
        }.clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .contain).accessibilityLabel("邀请券")
    }

    /// 邀请记录：#ECECE8 描边、圆角 15.5 的卡；标题 + 邀请码小签，右侧三项统计（为 0 时数字转灰）；「领取返现」三步走在 #F6F6F3 条里。
    private func ledger(_ mine: JSONValue, _ rewards: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                HStack(spacing: 10) {
                    Text("我的邀请记录").font(V3.sans(15, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19))
                    Text(mine.text("code")).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: 0x62625D)).padding(.horizontal, 8).frame(height: 19)
                        .background(Color(hex: 0xF6F6F3), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                HStack(spacing: 22) {
                    stat("待结算", yuan(mine.text("pendingAmount")), zero: (Double(mine.text("pendingAmount")) ?? 0) == 0)
                    stat("已到账", yuan(mine.text("paidAmount")), zero: (Double(mine.text("paidAmount")) ?? 0) == 0)
                    stat("已邀请", "\(mine["invitedCount"]?.integer ?? 0) 人", zero: (mine["invitedCount"]?.integer ?? 0) == 0)
                }
            }.frame(minHeight: 22)
            HStack(spacing: 12) {
                Text("领取返现").font(V3.sans(12.5, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19))
                HStack(spacing: 10) {
                    ForEach(Array(["截图这份记录", "添加客服微信并发送截图", "核实后用微信或支付宝转给你"].enumerated()), id: \.offset) { index, step in
                        if index > 0 { Text("→").foregroundStyle(Color(hex: 0x9A9A94)) }
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19)).frame(width: 17, height: 17)
                                .background(.white, in: Circle()).overlay(Circle().stroke(Color(hex: 0xDCDCD6)))
                            Text(step).foregroundStyle(Color(hex: 0x62625D))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("查看客服微信") { qrOpen = true }.buttonStyle(AccountInviteButtonStyle(height: 25, size: 12))
            }.font(V3.sans(12.5)).padding(.leading, 14).padding(.trailing, 8).frame(height: 38).background(Color(hex: 0xF6F6F3), in: RoundedRectangle(cornerRadius: 10))
            if records.isEmpty {
                // 还没有记录：淡出的示例行上面叠一段分享提示（06.12 占位暗示分享）
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(Array(rewards.prefix(4).enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 12) {
                                Circle().strokeBorder(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 27, height: 27)
                                Text("好友 \(String(UnicodeScalar(65 + index)!)) 开通\(row.text("title"))").foregroundStyle(Color(hex: 0x9C9C96)).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                                Capsule().fill(Color(hex: 0xF1F1EE)).frame(width: 40, height: 16)
                                Text("+\(row.text("reward"))").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(V3.txt)
                            }.font(V3.sans(13.5)).padding(.vertical, 12)
                                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(V3.line).frame(height: 1) } }
                        }
                    }.mask(LinearGradient(stops: [.init(color: .black, location: 0.15), .init(color: .clear, location: 0.85)], startPoint: .top, endPoint: .bottom)).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("还没有好友用你的邀请码开通会员").font(V3.sans(14, weight: .medium)).foregroundStyle(Color(hex: 0x1F1F1C))
                        Text("把邀请文案发到同学群或求职群，好友开通后返现会记在这里").font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x6B6B66))
                        Button(copied == "text" ? "已复制" : "复制邀请文案") { copy("text", mine) }.buttonStyle(AccountInviteButtonStyle(height: 35, size: 13)).padding(.top, 12)
                    }.padding(.top, 150).padding(.bottom, 16)
                }.frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, row in recordRow(row, first: index == 0) }
                    }
                }.scrollIndicators(.never)
            }
        }.frame(maxHeight: .infinity, alignment: .top).padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
            .overlay(RoundedRectangle(cornerRadius: 15.5).stroke(Color(hex: 0xECECE8)))
    }

    private func stat(_ label: String, _ value: String, zero: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(V3.sans(12)).foregroundStyle(Color(hex: 0x9A9A94))
            Text(value).font(.system(size: 18, weight: .semibold)).foregroundStyle(zero ? Color(hex: 0x9C9C96) : V3.txt)
        }
    }

    private func recordRow(_ row: JSONValue, first: Bool) -> some View {
        let status = row.text("status")
        let tag: (String, Color, Color) = ["pending": ("待结算", Color(hex: 0xFBF0E2), Color(hex: 0xB8661A)), "paid": ("已到账", Color(hex: 0xE7F3EC), Color(hex: 0x2E7D4F))][status]
            ?? ("已退款", Color(hex: 0xF1F1EE), V3.fnt)
        let date = CareerApplication.date(row.text("createTime")).map { d in let p = Beijing.calendar.dateComponents([.month, .day], from: d); return String(format: "%d-%02d", p.month ?? 0, p.day ?? 0) } ?? ""
        return HStack(spacing: 12) {
            Text(String(row.text("buyerLabel").prefix(1))).font(V3.sans(12)).foregroundStyle(V3.sub).frame(width: 28, height: 28).background(Color(hex: 0xF3F3F0), in: Circle())
            Text("\(row.text("buyerLabel")) 开通\(row.text("planTitle"))").foregroundStyle(status == "void" ? V3.fnt : V3.txt).frame(maxWidth: .infinity, alignment: .leading)
            Text(date).font(.system(size: 12)).foregroundStyle(V3.fnt)
            Text(tag.0).font(V3.sans(11.5, weight: .medium)).foregroundStyle(tag.2).padding(.horizontal, 8).padding(.vertical, 1).background(tag.1, in: Capsule())
            Text(yuan(row.text("amount"))).font(.system(size: 13.5, weight: .medium)).strikethrough(status == "void").foregroundStyle(status == "void" ? V3.fnt : V3.txt).frame(width: 64, alignment: .trailing)
        }.font(V3.sans(13.5)).padding(.vertical, 11.5).overlay(alignment: .top) { if !first { Rectangle().fill(V3.cl).frame(height: 1) } }
    }

    private func copy(_ kind: String, _ mine: JSONValue) {
        let origin = (session.api as? HTTPAPIClient)?.origin.absoluteString ?? ""
        let text = kind == "code" ? mine.text("code")
            : "我在用 DrawOffer 准备求职。开通会员时填写我的邀请码 \(mine.text("code"))，立减 ¥\(amount(mine.text("discountAmount")))：\(origin)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        Task { try? await Task.sleep(for: .seconds(1.6)); if copied == kind { copied = nil } }
    }

    private func load() async {
        do {
            async let code = session.api.careerRequest(path: "/api/billing/invite-code", method: "GET", query: [:], body: nil)
            async let list = session.api.careerRequest(path: "/api/billing/invite-rewards", method: "GET", query: ["limit": "20"], body: nil)
            let (a, b) = try await (code, list)
            mine = a; records = b["items"]?.items ?? []; failed = false
        } catch { failed = true }
    }
}

/// 邀请好友里的小按钮：墨黑实心或白底 #DCDCD6 描边，圆角 7.5。
private struct AccountInviteButtonStyle: ButtonStyle {
    var dark = false
    var height: CGFloat = 30
    var size: CGFloat = 12.5
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(size, weight: .medium)).foregroundStyle(dark ? .white : Color(hex: 0x1B1B19))
            .padding(.horizontal, 13).frame(height: height)
            .background(dark ? (configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt) : (configuration.isPressed ? V3.field : .white), in: RoundedRectangle(cornerRadius: 7.5))
            .overlay(RoundedRectangle(cornerRadius: 7.5).stroke(dark ? .clear : Color(hex: 0xDCDCD6)))
            .contentShape(RoundedRectangle(cornerRadius: 7.5))
    }
}

/// 客服微信二维码：盖在额度弹窗里的一层（Esc 只关这一层）。图片是 Web 站点的公开静态文件。
private struct SupportQR: View {
    let api: any APIClient
    let close: () -> Void
    var body: some View {
        ZStack {
            // 遮罩由 PlansSheet 的 qrLayer 画（06.13：整张弹窗盖 28% 深色）
            VStack(spacing: 10) {
                Text("添加客服微信").font(V3.sans(20, weight: .medium)).foregroundStyle(V3.txt)
                Text("用微信扫码添加，发送邀请记录截图").font(V3.sans(14)).foregroundStyle(Color(hex: 0x9A9A94))
                AsyncImage(url: (api as? HTTPAPIClient).flatMap { URL(string: "/support-wechat-qr.png", relativeTo: $0.origin) }) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Text("二维码暂时无法显示，请稍后再试").font(V3.sans(12.5)).foregroundStyle(V3.fnt).padding(24) }
                    else { ProgressView() }
                }.frame(width: 278.6, height: 278.6).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xECECE8), lineWidth: 1.4))
                Text("核实后用微信或支付宝把返现转给你").font(V3.sans(14)).foregroundStyle(Color(hex: 0x9A9A94))
            }
            .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 28).frame(width: 400)
            .background(.white, in: RoundedRectangle(cornerRadius: 20)).shadow(color: .black.opacity(0.16), radius: 20, y: 16)
            .overlay(alignment: .topTrailing) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Color(hex: 0x62625D)).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(.top, 14).padding(.trailing, 8)
            }
        }
    }
}
