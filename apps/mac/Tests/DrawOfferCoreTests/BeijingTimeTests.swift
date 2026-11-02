import Foundation
import Testing
@testable import DrawOfferCore

@Test func beijingCalendarReadsWallClockInShanghai() {
    // 2026-06-10 16:30 UTC is 00:30 on 11 June in Beijing.
    let instant = Date(timeIntervalSince1970: 1_781_109_000)
    let parts = Beijing.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
    #expect(parts.year == 2026 && parts.month == 6 && parts.day == 11 && parts.hour == 0 && parts.minute == 30)
    #expect(Beijing.formatter("yyyy-MM-dd HH:mm").string(from: instant) == "2026-06-11 00:30")
    #expect(Beijing.calendar.startOfDay(for: instant) == Date(timeIntervalSince1970: 1_781_107_200))
    #expect(Beijing.identifier == "Asia/Shanghai")
}

@Test func dayHelpersDefaultToBeijing() {
    // In UTC this instant is still 10 June; the default calendar must place it on the Beijing day, 11 June.
    let instant = Date(timeIntervalSince1970: 1_781_109_000)
    // Thursday 11 June in Beijing: the week starts Monday 8 June 00:00 Beijing, 7 June 16:00 UTC.
    #expect(ScheduleCalendar.weekStart(instant) == Date(timeIntervalSince1970: 1_780_848_000))
}
