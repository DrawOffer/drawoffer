import AppKit
import DrawOfferCore
import SwiftUI

/// 我的额度（Web `assistant/CardDialog.tsx` + `ChatCard` + `CreditsPanel` + `InvitePanel`）：900 宽、四个标签同高的弹窗。
/// 方案由后端 `GET /api/agent/cards/plans` 描述（分组即标签），后面接客户端自己的「积分明细」「邀请好友」。
/// 付款在浏览器的支付宝页面完成，这里轮询票据直到有结果。
struct PlansSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let card { content(card) } else { stateView }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(width: 900, height: 822, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(V3.fnt).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(.top, 26).padding(.trailing, 26)
        }
        .task(id: retry) { await load() }
        .task(id: opened?.ticket ?? "") { await poll() }
    }

    private var stateView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我的额度").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 52).padding(.bottom, 12)
            if status == "loading" { Text("正在加载方案…").font(V3.sans(14)).foregroundStyle(V3.sub) }
            else {
                Text(status == "error" ? "暂时无法读取方案，请重试。" : "暂无可用方案").font(V3.sans(14)).foregroundStyle(V3.sub)
                Button("重试") { retry += 1 }.buttonStyle(V3ButtonStyle(kind: .ghost))
            }
        }
    }

    @ViewBuilder private func content(_ card: JSONValue) -> some View {
        // `.chat-card-head`：28/52 标题，右侧状态 14/500
        HStack(spacing: 16) {
            Text(card.text("title")).font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 52)
            Spacer(minLength: 0)
            Text(card.text("status")).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
        }.padding(.trailing, 48)
        tabs(card)
        switch extra {
        case "credits": CreditsPanel().frame(maxHeight: .infinity, alignment: .top)
        case "invite": InvitePanel().frame(maxHeight: .infinity, alignment: .top)
        default: plans(card)
        }
        if let error { Text(error).font(V3.sans(14)).foregroundStyle(V3.red).padding(.top, 12) }
    }

    /// `.chat-card-tablist`：96 宽、40 高的标签，选中项 2px 下划线；右侧「会员与积分说明 ↗」。
    private func tabs(_ card: JSONValue) -> some View {
        let tabGroups = groups.isEmpty ? [("__items", "方案")] : groups.map { ($0.text("id"), $0.text("label")) }
        let notes = (activeGroup?["notes"]?.items ?? []).compactMap(\.stringValue)
        return HStack(alignment: .top, spacing: 12) {
            ForEach(tabGroups, id: \.0) { item in tab(item.1, active: extra == nil && (item.0 == activeGroup?.text("id") || item.0 == "__items")) { group = item.0; extra = nil } }
            tab("积分明细", active: extra == "credits") { extra = "credits" }
            tab("邀请好友", active: extra == "invite") { extra = "invite" }
            Spacer(minLength: 0)
            if !notes.isEmpty {
                Button { WebBridge.open("/pricing/credits", api: session.api) } label: { Text("会员与积分说明 ↗") }
                    .buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(height: 40)
            }
        }.frame(minHeight: 40).padding(.top, 16)
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(active ? V3.txt : V3.sub).padding(.top, 8).frame(width: 96, height: 40, alignment: .top)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(V3.txt).frame(height: 2) } }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder private func plans(_ card: JSONValue) -> some View {
        if !card.text("text").isEmpty { Text(card.text("text")).font(V3.sans(12)).foregroundStyle(V3.sub).frame(height: 20).padding(.top, 16) }
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in planCard(item) }
        }.frame(maxHeight: .infinity, alignment: .top).padding(.top, 16)
        if let selected, let action = selected["action"], action != .null { checkout(card, selected, action) }
    }

    /// `.chat-card-item`：圆角 14、内边距 24；单选点、徽标、价格 34px、类比胶囊、积分 20px、权益列表。
    private func planCard(_ item: JSONValue) -> some View {
        let selectable = item["action"] != nil && item["action"] != .null
        let on = selectable && item.text("id") == selected?.text("id")
        let dimmed = locked && !on || busy != nil && !on
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if selectable { Circle().strokeBorder(on ? V3.txt : Color(hex: 0xCFCFCA), lineWidth: on ? 5 : 1.5).background(Circle().fill(.white)).frame(width: 16, height: 16) }
                Text(item.text("title")).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                Spacer(minLength: 0)
                if !item.text("badge").isEmpty {
                    let featured = item["featured"]?.bool == true
                    Text(item.text("badge")).font(V3.sans(11.5, weight: .medium)).foregroundStyle(featured ? V3.blue : V3.sub).padding(.horizontal, 8).frame(height: 22)
                        .background(featured ? Color(hex: 0xEEF3FD) : V3.field, in: RoundedRectangle(cornerRadius: featured ? 10 : 6))
                }
            }.frame(minHeight: 26)
            if !item.text("price").isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.text("price")).font(.system(size: 34, weight: .semibold)).foregroundStyle(V3.txt)
                        if !item.text("period").isEmpty { Text(item.text("period")).font(V3.sans(12)).foregroundStyle(V3.sub) }
                    }.frame(height: 55)
                    if let analogy = item["analogy"], analogy != .null {
                        HStack(spacing: 6) {
                            Image(systemName: ["coffee": "cup.and.saucer", "tea": "mug", "chicken": "takeoutbag.and.cup.and.straw", "pot": "frying.pan", "film": "film"][analogy.text("icon")] ?? "sparkle")
                                .font(.system(size: 12)).foregroundStyle(V3.orange).frame(width: 16, height: 16)
                            Text(analogy.text("text")).font(V3.sans(13.5, weight: .medium))
                        }.foregroundStyle(Color(hex: 0x9A5A1C)).padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 4).background(Color(hex: 0xFDF1E3), in: Capsule())
                    }
                }
            }
            if !item.text("headline").isEmpty || !item.text("subline").isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    if !item.text("headline").isEmpty { Text(item.text("headline")).font(V3.sans(20, weight: .medium)).foregroundStyle(V3.txt).frame(height: 32) }
                    if !item.text("subline").isEmpty { Text(item.text("subline")).font(V3.sans(11.5)).foregroundStyle(V3.sub).lineHeight(11.5, 19).fixedSize(horizontal: false, vertical: true) }
                }.padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Rectangle().fill(V3.cl).frame(height: 1) }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((item["lines"]?.items ?? []).compactMap(\.stringValue).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(on ? V3.blue : V3.fnt).frame(width: 14).padding(.top, 4)
                        Text(line).font(V3.sans(13)).foregroundStyle(V3.sub).lineHeight(13, 21).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !item.text("note").isEmpty { Text(item.text("note")).font(V3.sans(12)).foregroundStyle(V3.sub) }
            Spacer(minLength: 0)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selectable ? Color.white : Color(hex: 0xFCFCFB), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? V3.txt : V3.cl, lineWidth: on ? 1.5 : 1))
        .opacity(dimmed ? 0.55 : 1).contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { if selectable && !locked && busy == nil { picks[pickKey] = item.text("id") } }
        .accessibilityElement(children: .combine).accessibilityAddTraits(on ? [.isSelected, .isButton] : selectable ? .isButton : [])
    }

    /// `.chat-card-checkout`：上边线，左侧邀请码 / 付款进度，右侧应付金额与唯一的黑色按钮（48 高、圆角 10）。
    private func checkout(_ card: JSONValue, _ selected: JSONValue, _ action: JSONValue) -> some View {
        let inviteHere = card["invite"].flatMap { inv in inv != .null && buyable.contains { $0.text("group") == inv.text("group") } ? inv : nil }
        let priced = invite?["prices"]?[action.text("id")]
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
                        if let priced, phase == "idle" { Text(priced.text("original")).font(.system(size: 13)).strikethrough().foregroundStyle(V3.fnt) }
                        Text((phase == "idle" ? priced?.text("price").nonEmptyValue : nil) ?? action.text("amount").nonEmptyValue ?? selected.text("price"))
                            .font(.system(size: 26, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 31)
                    }
                    if !action.text("caption").isEmpty { Text(action.text("caption")).font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
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

    /// `.chat-card-coupon`：48 高、虚线蓝框的邀请码输入；核对成功后变成浅蓝底的已减提示。
    @ViewBuilder private func coupon(_ config: JSONValue) -> some View {
        if let invite {
            HStack(spacing: 10) {
                Image(systemName: "ticket").font(.system(size: 13)).foregroundStyle(V3.blue)
                Text(invite.text("code")).font(.system(size: 14, weight: .medium)).tracking(0.8).foregroundStyle(V3.txt)
                Text("已减 \(invite.text("discount"))").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue).frame(maxWidth: .infinity, alignment: .leading)
                Button("移除") { self.invite = nil; inviteText = ""; inviteError = nil }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.fnt).disabled(busy != nil)
            }.padding(.leading, 14).padding(.trailing, 14).frame(maxWidth: 340, minHeight: 48)
                .background(Color(hex: 0xEEF3FD), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xC9D7F5)))
        } else {
            HStack(spacing: 10) {
                Image(systemName: "ticket").font(.system(size: 13)).foregroundStyle(V3.blue)
                ZStack(alignment: .leading) {
                    if inviteText.isEmpty {
                        (Text(config.text("label")) + Text(config.text("entry").isEmpty ? "" : "，") + Text(config.text("entry")).foregroundColor(V3.blue).fontWeight(.medium))
                            .font(V3.sans(13)).foregroundStyle(V3.fnt).lineLimit(1).allowsHitTesting(false)
                    }
                    TextField("", text: $inviteText).textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).tracking(0.8).accessibilityLabel(config.text("label"))
                        .onChange(of: inviteText) { inviteText = String(inviteText.uppercased().prefix(32)); inviteError = nil }
                        .onSubmit { Task { await checkInvite() } }
                }
                Button(checking ? "正在核对…" : "使用") { Task { await checkInvite() } }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue)
                    .padding(.horizontal, 16).frame(height: 36).background(Color(hex: 0xEEF3FD), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(checking || inviteText.trimmingCharacters(in: .whitespaces).isEmpty).opacity(checking || inviteText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.55 : 1)
            }.padding(.leading, 14).padding(.trailing, 6).frame(maxWidth: 340, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x9DB7EC), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                .overlay(alignment: .bottomLeading) { if let inviteError { Text(inviteError).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize().offset(x: 2, y: 20) } }
        }
    }

    /// 付款进度（Figma 13.50–13.54）：等待中可重新打开支付宝页；结束后显示后端给的结果文字。
    private var payStatus: some View {
        let tone = phase == "waiting" ? "wait" : phase == "done" ? "ok" : phase == "closed" ? "info" : "warn"
        let colors: [String: (Color, Color)] = ["wait": (Color(hex: 0xEEF3FD), V3.blue), "ok": (Color(hex: 0xEAF6EE), Color(hex: 0x2F9A5B)),
                                                "info": (V3.field, V3.sub), "warn": (Color(hex: 0xFDF3E7), Color(hex: 0xC9781A))]
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

private struct CheckoutStyle: ButtonStyle {
    var ghost = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14, weight: .medium)).foregroundStyle(ghost ? V3.txt : .white).padding(.horizontal, 28).frame(minWidth: 140, minHeight: 48)
            .background(ghost ? Color.white : configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ghost ? V3.cl : .clear)).opacity(enabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 积分明细（Figma 13.8C / 13.8D）

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
        }.padding(.top, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(member ? "会员积分" : "本月免费积分").font(V3.sans(13)).foregroundStyle(V3.sub).frame(height: 19)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(BillingSummary.credits(summary.display("available"))).font(.system(size: 40, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 48)
                        Text("积分可用").font(V3.sans(14)).foregroundStyle(V3.sub)
                    }
                }
                Spacer()
                Text("已用 \(percent)%").font(V3.sans(14, weight: .medium)).foregroundStyle(warn ? Color(hex: 0xD47C28) : V3.txt)
            }
            GeometryReader { geometry in
                Capsule().fill(Color(hex: 0xEEEEEA)).overlay(alignment: .leading) {
                    Capsule().fill(warn ? Color(hex: 0xD47C28) : Color(hex: 0x2B2B28)).frame(width: max(10, geometry.size.width * share))
                }
            }.frame(height: 10).accessibilityLabel("已用积分").accessibilityValue("\(percent)%")
            HStack {
                Text("\(member ? "本期" : "本月")已用 \(BillingSummary.credits(String(used))) / \(BillingSummary.credits(String(total)))")
                Spacer()
                Text(reset)
            }.font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(height: 22)
            if number(summary["overdraft"]) > 0 { Text("含透支 \(BillingSummary.credits(summary.display("overdraft"))) 积分，下次获得积分时先抵扣").font(V3.sans(12)).foregroundStyle(V3.fnt) }
            else if !member && extra == 0 { Text("免费积分只能用基础模型；开通会员可用全部模型").font(V3.sans(12)).foregroundStyle(V3.fnt) }
        }.padding(.bottom, 24).overlay(alignment: .bottom) { Rectangle().fill(V3.cl).frame(height: 1) }
        HStack(spacing: 16) {
            Text("积分变动").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22)
            HStack(spacing: 4) {
                ForEach([("all", "全部"), ("use", "使用"), ("gain", "获得")], id: \.0) { item in
                    Button(item.1) { direction = item.0 }.buttonStyle(.plain).font(V3.sans(12.5, weight: direction == item.0 ? .medium : .regular))
                        .foregroundStyle(direction == item.0 ? V3.txt : V3.fnt).padding(.horizontal, 6).frame(height: 26)
                        .accessibilityAddTraits(direction == item.0 ? .isSelected : [])
                }
            }
            Spacer()
            if let month { Text("本月使用 \(BillingSummary.credits(month.display("used"))) · 获得 \(BillingSummary.credits(month.display("gained")))").font(V3.sans(12)).foregroundStyle(V3.fnt) }
        }.padding(.top, 20).padding(.bottom, 6)
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
            Text(row.text("title")).font(V3.sans(14)).foregroundStyle(muted ? V3.fnt : V3.txt).lineLimit(1).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            Text(stamp(row.text("occurTime"))).font(.system(size: 12.5)).foregroundStyle(V3.fnt)
            Text(points > 0 ? "+" + BillingSummary.credits(row.display("points")) : BillingSummary.credits(row.display("points")).replacingOccurrences(of: "-", with: "−"))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(muted ? V3.fnt : points > 0 ? Color(hex: 0x2F9A5B) : V3.txt).frame(width: 72, alignment: .trailing)
        }.padding(.vertical, 12).overlay(alignment: .top) { if !first { Rectangle().fill(V3.cl).frame(height: 1) } }
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

// MARK: - 邀请好友（Figma 13.39）

private struct InvitePanel: View {
    @Environment(SessionStore.self) private var session
    @State private var mine: JSONValue?
    @State private var records: [JSONValue] = []
    @State private var failed = false
    @State private var copied: String?
    @State private var qrOpen = false

    var body: some View {
        Group {
            if failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("暂时无法读取邀请信息，请重试。").font(V3.sans(14)).foregroundStyle(V3.sub)
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            } else if let mine { panel(mine) }
            else { Text("正在加载…").font(V3.sans(14)).foregroundStyle(V3.sub) }
        }.padding(.top, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { if qrOpen { SupportQR(api: session.api) { qrOpen = false } } }
        .task { await load() }
    }

    private func yuan(_ value: String) -> String { String(format: "¥%.2f", Double(value) ?? 0) }
    private func amount(_ value: String) -> String { let number = Double(value) ?? 0; return number == number.rounded() ? "\(Int(number))" : String(number) }

    @ViewBuilder private func panel(_ mine: JSONValue) -> some View {
        let rewards = mine["rewards"]?.items ?? []
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                coupon(mine).frame(width: 400)
                VStack(alignment: .leading, spacing: 0) {
                    Text("好友每开通一次会员，你得到现金返现").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22)
                    Spacer(minLength: 14)
                    HStack(spacing: 0) {
                        ForEach(Array(rewards.enumerated()), id: \.offset) { index, row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.text("title")).font(V3.sans(12)).foregroundStyle(V3.sub).frame(height: 22)
                                Text(row.text("reward")).font(.system(size: 26, weight: .semibold)).foregroundStyle(V3.blue).frame(height: 32)
                                Text("好友付 \(row.text("price"))").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                            }.padding(.leading, index > 0 ? 16 : 0).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(V3.cl).frame(width: 1) } }
                        }
                    }
                    Spacer(minLength: 14)
                    Text("返现按好友开通的会员档位计算，核实后用微信或支付宝转给你").font(V3.sans(11.5)).foregroundStyle(V3.fnt).frame(height: 22)
                }.padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading).frame(height: 184)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(V3.cl))
            }
            ledger(mine, rewards).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// 邀请券：左侧立减金额，右侧邀请码与两个复制按钮；中间两个缺口。
    private func coupon(_ mine: JSONValue) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("好友开通会员").font(V3.sans(12)).frame(height: 22)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("立减").font(V3.sans(14, weight: .medium))
                    Text("¥\(amount(mine.text("discountAmount")))").font(.system(size: 44, weight: .semibold)).frame(height: 52)
                }
            }.foregroundStyle(V3.blue).frame(width: 136).frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Rectangle().stroke(V3.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: 1).padding(.vertical, 16) }
            VStack(alignment: .leading, spacing: 6) {
                Text("我的邀请码").font(V3.sans(12)).foregroundStyle(V3.sub).frame(height: 22)
                Text(mine.text("code")).font(.system(size: 30, weight: .semibold)).tracking(3).foregroundStyle(V3.txt).frame(height: 38)
                HStack(spacing: 8) {
                    Button(copied == "code" ? "已复制" : "复制邀请码") { copy("code", mine) }.buttonStyle(V3ButtonStyle(kind: .dark, height: 28, small: true))
                    Button(copied == "text" ? "已复制" : "复制邀请文案") { copy("text", mine) }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 28, small: true))
                }.padding(.top, 10)
            }.padding(.leading, 24).padding(.trailing, 20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 184).background(Color(hex: 0xEEF3FD))
        .mask {
            Rectangle().overlay(alignment: .topLeading) { Circle().frame(width: 22, height: 22).offset(x: 125, y: -11).blendMode(.destinationOut) }
                .overlay(alignment: .bottomLeading) { Circle().frame(width: 22, height: 22).offset(x: 125, y: 11).blendMode(.destinationOut) }.compositingGroup()
        }.clipShape(RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .contain).accessibilityLabel("邀请券")
    }

    private func ledger(_ mine: JSONValue, _ rewards: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                HStack(spacing: 10) {
                    Text("我的邀请记录").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                    Text(mine.text("code")).font(.system(size: 12)).tracking(0.7).foregroundStyle(V3.sub).padding(.horizontal, 8).padding(.vertical, 2).background(V3.field, in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                HStack(spacing: 22) {
                    stat("待结算", yuan(mine.text("pendingAmount")), Color(hex: 0xB8661A))
                    stat("已到账", yuan(mine.text("paidAmount")), V3.txt)
                    stat("已邀请", "\(mine["invitedCount"]?.integer ?? 0) 人", V3.txt)
                }
            }.frame(minHeight: 29)
            HStack(spacing: 12) {
                Text("领取返现").font(V3.sans(12.5, weight: .bold))
                HStack(spacing: 10) {
                    ForEach(Array(["截图这份记录", "添加客服微信并发送截图", "核实后用微信或支付宝转给你"].enumerated()), id: \.offset) { index, step in
                        if index > 0 { Text("→").foregroundStyle(V3.fnt) }
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.system(size: 10.5)).foregroundStyle(V3.txt).frame(width: 18, height: 18).background(.white, in: Circle()).overlay(Circle().stroke(Color(hex: 0xDCDCD6)))
                            Text(step)
                        }
                    }
                }.foregroundStyle(V3.sub).frame(maxWidth: .infinity, alignment: .leading)
                Button { qrOpen = true } label: { Label("查看客服微信", systemImage: "message.fill").labelStyle(.titleAndIcon) }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 28, small: true))
            }.font(V3.sans(12.5)).padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8).background(V3.field, in: RoundedRectangle(cornerRadius: 10))
            if records.isEmpty {
                // 还没有记录：淡出的示例行上面叠一段分享提示（Figma 13.40E）
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(Array(rewards.prefix(4).enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 12) {
                                Circle().strokeBorder(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 28, height: 28)
                                Text("好友 \(String(UnicodeScalar(65 + index)!)) 开通\(row.text("title"))").frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                                Capsule().fill(Color(hex: 0xF1F1EE)).frame(width: 40, height: 16)
                                Text("+\(row.text("reward"))").fontWeight(.semibold).foregroundStyle(V3.blue)
                            }.font(V3.sans(13.5)).foregroundStyle(V3.fnt).padding(.vertical, 11)
                                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(V3.cl).frame(height: 1) } }
                        }
                    }.mask(LinearGradient(stops: [.init(color: .black, location: 0.2), .init(color: .clear, location: 0.85)], startPoint: .top, endPoint: .bottom)).accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("还没有好友用你的邀请码开通会员").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                        Text("把邀请文案发到同学群或求职群，好友开通后返现会记在这里").font(V3.sans(12.5)).foregroundStyle(V3.sub)
                        Button(copied == "text" ? "已复制" : "复制邀请文案") { copy("text", mine) }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 28, small: true)).padding(.top, 8)
                    }.padding(.top, 110).padding(.bottom, 16)
                }.frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.offset) { index, row in recordRow(row, first: index == 0) }
                    }
                }.scrollIndicators(.never)
            }
        }.frame(maxHeight: .infinity, alignment: .top).padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8).overlay(RoundedRectangle(cornerRadius: 16).stroke(V3.cl))
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { Text(label).font(V3.sans(12)).foregroundStyle(V3.fnt); Text(value).font(.system(size: 18, weight: .semibold)).foregroundStyle(color) }
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
        }.font(V3.sans(13.5)).padding(.vertical, 11).overlay(alignment: .top) { if !first { Rectangle().fill(V3.cl).frame(height: 1) } }
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

/// 客服微信二维码：盖在额度弹窗里的一层（Esc 只关这一层）。图片是 Web 站点的公开静态文件。
private struct SupportQR: View {
    let api: any APIClient
    let close: () -> Void
    var body: some View {
        ZStack {
            Color(hex: 0x141412).opacity(0.28).onTapGesture(perform: close)
            VStack(spacing: 10) {
                Text("添加客服微信").font(V3.sans(20, weight: .medium)).foregroundStyle(V3.txt)
                Text("用微信扫码添加，发送邀请记录截图").font(V3.sans(14)).foregroundStyle(V3.fnt)
                AsyncImage(url: (api as? HTTPAPIClient).flatMap { URL(string: "/support-wechat-qr.png", relativeTo: $0.origin) }) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Text("二维码暂时无法显示，请稍后再试").font(V3.sans(12.5)).foregroundStyle(V3.fnt).padding(24) }
                    else { ProgressView() }
                }.frame(width: 280, height: 280).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl)).padding(.vertical, 4)
                Text("核实后用微信或支付宝把返现转给你").font(V3.sans(14)).foregroundStyle(V3.fnt)
            }
            .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 28).frame(width: 400)
            .background(.white, in: RoundedRectangle(cornerRadius: 20)).shadow(color: .black.opacity(0.16), radius: 20, y: 16)
            .overlay(alignment: .topTrailing) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.sub).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(16)
            }
        }
    }
}
