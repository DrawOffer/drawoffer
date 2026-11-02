import Foundation

/// Beijing time, the one time zone the product shows and counts days in.
///
/// Times travel as UTC ISO 8601; only their wall-clock reading is fixed to Asia/Shanghai, whatever
/// zone the Mac is set to. Use `Beijing.calendar` for day math and `Beijing.formatter` for display
/// instead of `Calendar.current`, `TimeZone.current` or a bare `DateFormatter()`.
public enum Beijing {
    public static let identifier = "Asia/Shanghai"
    public static let timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 8 * 3600)!

    /// Gregorian, Beijing zone, current locale for week rules that callers do not set themselves.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale.current
        return calendar
    }

    /// A formatter that reads dates in Beijing time.
    public static func formatter(_ pattern: String? = nil, locale: Locale? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if let locale { formatter.locale = locale }
        if let pattern { formatter.dateFormat = pattern }
        return formatter
    }
}
