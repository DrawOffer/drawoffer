import SwiftUI
import DrawOfferCore

/// 岗位广场的筛选下拉（Web `PoolFilterPanel.tsx`；macOS 稿 01.03–01.06）：城市、方向、发布时间、排序都在这里选，
/// 点「查看 N 个岗位」才生效，弹层里改的只是草稿。每个选项后面是按当前草稿算的数量（`/api/job-pool/count`，读缓存 2 分钟）。
struct PoolFilterPanel: View {
    static let width: CGFloat = 600
    @Environment(SessionStore.self) private var session
    let base: [String: String]
    let categories: [String]
    let categoriesLoading: Bool
    let apply: (PoolPanel) -> Void

    @State private var draft: PoolPanel
    @State private var cityText = ""
    @State private var allCities = false
    @State private var allCategories = false
    @State private var counts: (key: String, value: JSONValue)?
    /// 弹层打开后第一次拿到的城市顺序与各自数字的位数：之后换方向、时间只改数字，城市不跳动、不重排、不消失（没有匹配写 0）。
    @State private var cityOrder: [String]?
    @State private var digits: [String: Int] = [:]

    init(value: PoolPanel, base: [String: String], categories: [String], categoriesLoading: Bool, apply: @escaping (PoolPanel) -> Void) {
        self.base = base; self.categories = categories; self.categoriesLoading = categoriesLoading; self.apply = apply
        _draft = State(initialValue: value)
    }

    private var query: [String: String] { base.merging(draft.query) { $1 } }
    private var countKey: String { ReadCache.key(path: "", query: query) }
    private var pending: Bool { counts?.key != countKey }
    /// 城市数字不受城市选择影响，多选时每个城市仍显示自己的数。
    private var cityCounts: [String: Int] {
        Dictionary((counts?.value["cities"]?.items ?? []).map { ($0.text("name"), $0["count"]?.integer ?? 0) }, uniquingKeysWith: { first, _ in first })
    }
    private var needle: String { cityText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("工作城市") { cityOptions }
            if !categories.isEmpty || categoriesLoading { group("方向") { categoryOptions } }
            group("发布时间") {
                FlowLayout(spacing: 6) {
                    ForEach(JobPool.withins, id: \.value) { item in
                        PoolOption(label: item.label, active: draft.within == item.value) { draft.within = item.value }
                    }
                }
            }
            group("排序") {
                FlowLayout(spacing: 6) {
                    ForEach(JobPool.sorts, id: \.value) { item in
                        PoolOption(label: item.label, active: draft.sort == item.value) { draft.sort = item.value }
                    }
                }
            }
            footer.padding(.top, 4)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
        .frame(width: Self.width, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 12)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: countKey) {
            // 点选是离散的，立刻问；新数字到之前旧数字留在原处。
            let key = countKey
            guard let value = try? await session.api.careerRequest(path: "/api/job-pool/count", method: "GET", query: query, body: nil),
                  !Task.isCancelled, key == countKey else { return }
            counts = (key, value)
            if cityOrder == nil {
                let cities = value["cities"]?.items ?? []
                cityOrder = cities.map { $0.text("name") }
                digits = Dictionary(cities.map { ($0.text("name"), JobPool.grouped($0["count"]?.integer ?? 0).count) }, uniquingKeysWith: { first, _ in first })
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("筛选岗位")
    }

    private func group<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).frame(width: 84, height: 18, alignment: .leading).padding(.top, 5)
            VStack(alignment: .leading, spacing: 8, content: content).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }

    @ViewBuilder private var cityOptions: some View {
        let cities = JobPool.panelCities(order: cityOrder, counted: (counts?.value["cities"]?.items ?? []).map { $0.text("name") },
                                         picked: draft.cities, needle: needle, all: allCities)
        let more = JobPool.hasMoreCities(order: cityOrder, needle: needle)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(V3.fnt)
            TextField("", text: $cityText, prompt: Text("搜索城市名…").foregroundStyle(V3.fnt)).textFieldStyle(.plain).font(V3.sans(12))
                .accessibilityLabel("搜索城市")
        }
        .padding(.horizontal, 10).frame(width: 210, height: 28)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xDBDBD6)))
        let chips = FlowLayout(spacing: 6) {
            ForEach(cities, id: \.self) { name in
                let count = cityCounts[name] ?? 0
                PoolOption(label: name, active: draft.cities.contains(name), needle: needle,
                           count: counts == nil ? nil : JobPool.grouped(count), zero: count == 0, digits: digits[name] ?? 1) {
                    draft = draft.toggled(city: name)
                }
            }
            if !needle.isEmpty && cities.isEmpty { Text("没有找到这个城市").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 28) }
            if more && !allCities { moreButton("更多城市", down: true) { allCities = true } }
        }
        Group {
            if allCities && needle.isEmpty {
                ScrollView { chips.padding(.vertical, 1) }.frame(maxHeight: 172)
            } else { chips }
        }
        .frame(minHeight: cityOrder == nil ? 64 : nil, alignment: .topLeading)
        if more && allCities { moreButton("收起", down: false) { allCities = false }.padding(.top, -2) }
    }

    @ViewBuilder private var categoryOptions: some View {
        FlowLayout(spacing: 6) {
            if !categories.isEmpty {
                ForEach(JobPool.panelCategories(categories, picked: draft.categories, all: allCategories), id: \.self) { name in
                    PoolOption(label: name, active: draft.categories.contains(name)) { draft = draft.toggled(category: name) }
                }
                if categories.count > JobPool.shownCategories {
                    moreButton(allCategories ? "收起" : "更多方向", down: !allCategories) { allCategories.toggle() }
                }
            } else {
                ForEach([64, 52, 68, 56] as [CGFloat], id: \.self) { width in V3Skeleton(width: width, height: 28, radius: 8) }
            }
        }
    }

    private func moreButton(_ label: String, down: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) { Text(label); Image(systemName: down ? "chevron.right" : "chevron.up").font(.system(size: 8, weight: .semibold)) }
                .font(V3.sans(12)).foregroundStyle(V3.blue).padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            PoolCheckbox(label: "不看已加入投递看板的岗位", checked: draft.excludeJoined) { draft.excludeJoined.toggle() }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { draft = .empty; cityText = "" } label: {
                    Text("重置全部").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).frame(minWidth: 120).frame(height: 34).contentShape(Capsule())
                }.buttonStyle(.plain)
                Button { apply(draft) } label: {
                    HStack(spacing: 0) {
                        if let total = counts?.value["total"]?.integer {
                            Text("查看 "); Text(JobPool.grouped(total)).monospacedDigit().opacity(pending ? 0.55 : 1); Text(" 个岗位")
                        } else { Text("查看岗位") }
                    }
                    .font(V3.sans(13, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 16).frame(minWidth: 148).frame(height: 34)
                    .background(V3.txt, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityLabel("查看岗位")
            }
        }
        .padding(.top, 12).overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
    }
}

/// `.pool-opt`：28 高、圆角 8 的细边框选项；选中为浅蓝底蓝字蓝边。城市后接灰色小数字，0 更淡；搜索时输入部分标蓝。
private struct PoolOption: View {
    let label: String
    let active: Bool
    var needle = ""
    var count: String?
    var zero = false
    var digits = 1
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                name
                if let count {
                    Text(count).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(active ? V3.blue : zero ? V3.fnt2 : V3.fnt)
                        .frame(minWidth: CGFloat(digits) * 6.4, alignment: .leading)
                }
            }
            .font(V3.sans(12.5, weight: active ? .medium : .regular))
            .foregroundStyle(active ? V3.blue : hover ? V3.txt : V3.sub)
            .padding(.horizontal, 10).frame(height: 28)
            .background(active ? V3.blueSoft : .white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? V3.blue.opacity(0.45) : hover ? V3.fnt2 : V3.cl))
            .contentShape(Rectangle()).fixedSize()
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
    }

    private var name: Text {
        guard !needle.isEmpty, let range = label.range(of: needle) else { return Text(label) }
        return Text(label[..<range.lowerBound]) + Text(label[range]).foregroundColor(V3.blue) + Text(label[range.upperBound...])
    }
}

/// `.pool-panel-check`：16 方框，勾上为蓝底白勾。
struct PoolCheckbox: View {
    let label: String
    let checked: Bool
    var color: Color = V3.sub
    var size: CGFloat = 12.5
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(checked ? V3.blue : .white)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(checked ? V3.blue : V3.fnt2))
                    .overlay { if checked { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
                    .frame(width: 16, height: 16)
                Text(label).font(V3.sans(size)).foregroundStyle(color)
            }.contentShape(Rectangle()).fixedSize()
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(checked ? "已勾选" : "未勾选")
    }
}

/// 「只看符合我意向的」（Web `IntentToggle`，macOS 稿 01.02）：画像可用时勾选即生效；悬停 100ms 展开说明卡（离开 220ms 收起），
/// 说明按什么筛；未登录或缺目标岗位时勾不上，点一下原地展开同一张卡，指去填写。数字还没到时只放勾选框，不出卡片。
struct PoolIntentToggle: View {
    let checked: Bool
    let intent: PoolIntent?
    let openCareerProfile: () -> Void
    let change: (Bool) -> Void
    @State private var hovering = false
    @State private var open = false
    @State private var pinned = false

    private var ready: Bool { intent?.ready == true }

    var body: some View {
        PoolCheckbox(label: "只看符合我意向的", checked: intent == nil ? checked : ready && checked, color: checked && ready ? V3.txt : V3.sub, size: 13) {
            if ready {
                change(!checked)
                if !checked { open = true }
            } else if intent != nil { pinned = true; open = true }
        }
        .frame(height: 32)
        .overlay(alignment: .topLeading) {
            if let intent, open || pinned {
                card(intent).offset(x: -4, y: 38).transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard intent != nil else { return }
            try? await Task.sleep(for: .milliseconds(hovering ? 100 : 220))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                if hovering { open = true } else { open = false; pinned = false }
            }
        }
        .onExitCommand { open = false; pinned = false }
    }

    private func card(_ intent: PoolIntent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch intent.state {
            case "ready":
                Text("按求职画像筛选").font(V3.sans(12)).foregroundStyle(V3.fnt)
                Text(intent.summary).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true)
                if let tip = intent.tip { Text(tip).font(V3.sans(11.5)).foregroundStyle(V3.fnt).fixedSize(horizontal: false, vertical: true) }
                link("修改求职画像 ›")
            case "missing_role":
                Text("求职画像缺目标岗位").font(V3.sans(12)).foregroundStyle(V3.fnt)
                Text("先在求职画像里填目标岗位").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                link("去填写 ›")
            default:
                Text("未登录").font(V3.sans(12)).foregroundStyle(V3.fnt)
                Text("登录后按你的求职意向筛选").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minWidth: 180, maxWidth: 320, alignment: .leading).fixedSize()
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 12)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private func link(_ label: String) -> some View {
        Button { open = false; pinned = false; openCareerProfile() } label: { Text(label).font(V3.sans(12)).foregroundStyle(V3.blue) }
            .buttonStyle(.plain).pointingHandCursor()
    }
}
