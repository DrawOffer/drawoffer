import DrawOfferCore
import SwiftUI

/// 求职画像里的日期输入（macOS 稿 01 页 03.05–03.08），外观照 Web `CareerDateFields`：
/// 出生日期在同一个弹层里先选年月（03.05，标题年份可点开 12 年网格 03.06）、再选日（03.07）；
/// 经历的开始 / 结束时间只选年月（03.08 MonthCalendar：‹ 本月 ›，底部「清除」，结束时间多「至今」）。
/// 存的格式不变：出生日期 YYYY-MM-DD，经历 YYYY-MM 或「至今」。
enum AccountDates {
    static let present = "至今"
    static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// 读出简历里常见的年月写法：2023-09、2023.9、2023/09、2023年9月。
    static func yearMonth(_ value: String) -> (year: Int, month: Int)? {
        guard let match = value.trimmingCharacters(in: .whitespaces).firstMatch(of: /^(\d{4})\s*[-.\/年]\s*(\d{1,2})/),
              let year = Int(match.1), let month = Int(match.2), (1...12).contains(month) else { return nil }
        return (year, month)
    }

    static func date(_ value: String) -> (year: Int, month: Int, day: Int)? {
        guard let match = value.trimmingCharacters(in: .whitespaces).firstMatch(of: /^(\d{4})\s*[-.\/年]\s*(\d{1,2})\s*[-.\/月]\s*(\d{1,2})/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              (1...12).contains(month), (1...days(year, month)).contains(day) else { return nil }
        return (year, month, day)
    }

    static func days(_ year: Int, _ month: Int) -> Int {
        let calendar = Beijing.calendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return 30 }
        return calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    /// 当月 1 号是周几（周一为 0）。
    static func leading(_ year: Int, _ month: Int) -> Int {
        let calendar = Beijing.calendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return 0 }
        return (calendar.component(.weekday, from: date) + 5) % 7
    }

    static var today: (year: Int, month: Int) {
        let parts = Beijing.calendar.dateComponents([.year, .month], from: Date())
        return (parts.year ?? 2026, parts.month ?? 1)
    }
}

/// 日期字段的触发器：外观与输入框相同（40 高、圆角 6、#E4E4E0 描边），右侧小箭头；点开弹层。
struct AccountDateTrigger: View {
    let label: String
    let value: String
    let placeholder: String
    @Binding var open: Bool
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(value.isEmpty ? placeholder : value).font(V3.sans(14)).monospacedDigit().foregroundStyle(value.isEmpty ? V3.fnt2 : V3.txt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.fnt)
            }
            .padding(.horizontal, 15).frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(open ? V3.txt.opacity(0.5) : V3.cl))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(value.isEmpty ? "未填" : value)
    }
}

/// 03.05–03.07 出生日期：弹层先选年月，选月份后原地换成该月日历，点日期保存并关闭。
struct AccountBirthDateField: View {
    let label: String
    let value: String
    let commit: (String) -> Void
    @State private var open = false
    @State private var month: (year: Int, month: Int)?

    var body: some View {
        AccountDateTrigger(label: label, value: value, placeholder: "选择日期", open: $open)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                Group {
                    if let month {
                        AccountDayGrid(year: month.year, month: month.month, selected: AccountDates.date(value), back: { self.month = nil }) { day in
                            let next = "\(month.year)-\(AccountDates.pad(month.month))-\(AccountDates.pad(day))"
                            if next != value { commit(next) }
                            open = false
                        } shift: { delta in
                            var m = month.month + delta, y = month.year
                            if m < 1 { m = 12; y -= 1 } else if m > 12 { m = 1; y += 1 }
                            self.month = (y, m)
                        }
                    } else {
                        AccountMonthGrid(selected: AccountDates.date(value).map { ($0.year, $0.month) }, showThisMonth: false) { year, picked in
                            month = (year, picked)
                        }
                    }
                }
                .onDisappear { month = nil }
            }
    }
}

/// 03.08 经历开始 / 结束时间：选年月即保存；底部「清除」，结束时间多「至今」。
struct AccountYearMonthField: View {
    let label: String
    let value: String
    var allowPresent = false
    let commit: (String) -> Void
    @State private var open = false

    var body: some View {
        AccountDateTrigger(label: label, value: value, placeholder: "选择年月", open: $open)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AccountMonthGrid(selected: AccountDates.yearMonth(value), showThisMonth: true, pick: { year, month in pick("\(year)-\(AccountDates.pad(month))") }) {
                    HStack {
                        Button("清除") { pick("") }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(value.isEmpty ? V3.fnt2 : V3.fnt).disabled(value.isEmpty)
                        Spacer()
                        if allowPresent {
                            Button(AccountDates.present) { pick(AccountDates.present) }.buttonStyle(.plain).font(V3.sans(12))
                                .foregroundStyle(value == AccountDates.present ? .white : V3.txt).padding(.horizontal, 12).frame(height: 25)
                                .background(value == AccountDates.present ? V3.blue : .white, in: Capsule())
                                .overlay(Capsule().stroke(value == AccountDates.present ? .clear : V3.cl))
                        }
                    }.padding(.horizontal, 13).frame(height: 25).padding(.top, 4)
                }
            }
    }

    private func pick(_ next: String) {
        if next != value { commit(next) }
        open = false
    }
}

/// 年月网格（MonthCalendar）：顶部「2003 年 ▾」可点开 12 年网格；右侧 ‹（本月）›；3×4 月份，选中蓝底白字。
struct AccountMonthGrid<Footer: View>: View {
    let selected: (year: Int, month: Int)?
    var showThisMonth = true
    let pick: (Int, Int) -> Void
    @ViewBuilder var footer: () -> Footer
    @State private var year = AccountDates.today.year
    @State private var years = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { years.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(years ? "\(yearPage) – \(yearPage + 11)" : "\(String(year)) 年").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Text(years ? "▴" : "▾").font(.system(size: 10)).foregroundStyle(Color(hex: 0x96968F))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(years ? "收起年份" : "选择年份")
                Spacer()
                arrow("chevron.left") { year -= years ? 12 : 1 }
                if showThisMonth && !years {
                    Button("本月") { let now = AccountDates.today; pick(now.year, now.month) }.buttonStyle(.plain)
                        .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 6)
                }
                arrow("chevron.right") { year += years ? 12 : 1 }
            }.padding(.leading, 17).padding(.trailing, 13).frame(height: 24).padding(.top, 15)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(86), spacing: 6), count: 3), spacing: 6) {
                if years {
                    ForEach(yearPage..<(yearPage + 12), id: \.self) { value in
                        cell(String(value), on: value == year) { year = value; years = false }
                    }
                } else {
                    ForEach(1...12, id: \.self) { month in
                        cell("\(month) 月", on: selected.map { $0.year == year && $0.month == month } ?? false) { pick(year, month) }
                    }
                }
            }.padding(.top, 16).padding(.horizontal, 13)
            footer().padding(.top, 8)
        }
        .padding(.bottom, 13).frame(width: 296)
        .onAppear { if let selected { year = selected.year } }
    }

    /// 一页 12 年，以 2000 为基准对齐（2000–2011、2012–2023…）。
    private var yearPage: Int { year - (((year - 2000) % 12) + 12) % 12 }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(V3.sub).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }

    private func cell(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? .white : V3.txt)
                .frame(width: 86, height: 44).background(on ? V3.blue : .clear, in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
        }.buttonStyle(AccountGridCellStyle(on: on)).accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension AccountMonthGrid where Footer == EmptyView {
    init(selected: (year: Int, month: Int)?, showThisMonth: Bool = true, pick: @escaping (Int, Int) -> Void) {
        self.init(selected: selected, showThisMonth: showThisMonth, pick: pick, footer: { EmptyView() })
    }
}

/// 03.07 选日：‹ [2003 年 5 月 ⌄] ›，周一开头；月外日期 #B5B5B0，选中蓝底 36×32。
struct AccountDayGrid: View {
    let year: Int
    let month: Int
    let selected: (year: Int, month: Int, day: Int)?
    let back: () -> Void
    let pick: (Int) -> Void
    let shift: (Int) -> Void

    var body: some View {
        let lead = AccountDates.leading(year, month), count = AccountDates.days(year, month)
        let previous = AccountDates.days(month == 1 ? year - 1 : year, month == 1 ? 12 : month - 1)
        let total = ((lead + count + 6) / 7) * 7
        VStack(spacing: 0) {
            HStack {
                arrow("chevron.left") { shift(-1) }
                Spacer()
                Button(action: back) {
                    HStack(spacing: 4) {
                        Text("\(String(year)) 年 \(month) 月").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(V3.fnt)
                    }.padding(.horizontal, 8).frame(height: 22).background(V3.field, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityLabel("重新选择年月")
                Spacer()
                arrow("chevron.right") { shift(1) }
            }.padding(.horizontal, 15).frame(height: 24).padding(.top, 15)
            HStack(spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(V3.sans(12)).foregroundStyle(V3.fnt).frame(width: 36) }
            }.padding(.top, 14)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<total, id: \.self) { index in
                    let day = index - lead + 1
                    if day < 1 || day > count {
                        Text("\(day < 1 ? previous + day : day - count)").font(V3.sans(12)).foregroundStyle(Color(hex: 0xB5B5B0)).frame(width: 36, height: 32)
                    } else {
                        let on = selected.map { $0.year == year && $0.month == month && $0.day == day } ?? false
                        Button { pick(day) } label: {
                            Text("\(day)").font(V3.sans(12)).foregroundStyle(on ? .white : V3.txt).frame(width: 36, height: 32)
                                .background(on ? V3.blue : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }.buttonStyle(AccountGridCellStyle(on: on, radius: 7))
                    }
                }
            }.padding(.top, 6)
        }.padding(.bottom, 12).frame(width: 296)
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(V3.sub).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}

/// 网格单元：悬停只加很浅的底（不是灰色大块），选中项自己画蓝底。
private struct AccountGridCellStyle: ButtonStyle {
    var on: Bool
    var radius: CGFloat = 9
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(!on && (hover || configuration.isPressed) ? Color.black.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: radius))
            .onHover { hover = $0 }
    }
}
