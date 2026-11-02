using System.Globalization;
using System.Text.RegularExpressions;

namespace DrawOffer.Core.Models;

/// <summary>
/// Mac `CareerApplication.date` 的复刻：先用带小数秒、再用不带小数秒的 `ISO8601DateFormatter`，
/// 最后把不带时区的时间（如 `2026-10-31T06:28:41.227684`）按本地时区读，与浏览器 `new Date()` 一致。
/// 行为在 macOS 上逐例实测：小数秒截断到毫秒；ISO 解析器把越界日期顺延（2 月 30 日 → 3 月 2 日）、24 时顺延到次日；
/// 本地时间落在夏令时跳过的时段返回 null，重复时段取较晚的一次。
/// </summary>
internal static class SwiftDate
{
    static readonly Regex Internet = new(@"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|z|[+-]\d{2}(?::?\d{2})?)$", RegexOptions.CultureInvariant);
    static readonly Regex Local = new(@"^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.(\d+))?$", RegexOptions.CultureInvariant);

    public static DateTimeOffset? Parse(string text) => Parse(text, Beijing.Zone);

    public static DateTimeOffset? Parse(string text, TimeZoneInfo localZone)
    {
        // `\d` 在 .NET 里包含全角等数字，这里只认 ASCII。
        if (text.Any(c => c > '\x7f')) return null;
        var match = Internet.Match(text);
        if (match.Success)
        {
            if (Offset(match.Groups[8].Value) is not { } offset) return null;
            if (Wall(match, lenient: true) is not { } wall) return null;
            try { return new DateTimeOffset(wall, offset); } catch (ArgumentOutOfRangeException) { return null; }
        }
        match = Local.Match(text);
        if (!match.Success || Wall(match, lenient: false) is not { } local) return null;
        if (localZone.IsInvalidTime(local)) return null;
        var localOffset = localZone.IsAmbiguousTime(local) ? localZone.GetAmbiguousTimeOffsets(local).Min() : localZone.GetUtcOffset(local);
        return new DateTimeOffset(local, localOffset);
    }

    static TimeSpan? Offset(string zone)
    {
        if (zone is "Z" or "z") return TimeSpan.Zero;
        var digits = zone[1..].Replace(":", "");
        var hours = int.Parse(digits[..2], CultureInfo.InvariantCulture);
        var minutes = digits.Length > 2 ? int.Parse(digits[2..], CultureInfo.InvariantCulture) : 0;
        if (hours > 18 || minutes > 59) return null;
        var span = new TimeSpan(hours, minutes, 0);
        return zone[0] == '-' ? -span : span;
    }

    static DateTime? Wall(Match match, bool lenient)
    {
        int Field(int index) => int.Parse(match.Groups[index].Value, CultureInfo.InvariantCulture);
        int year = Field(1), month = Field(2), day = Field(3), hour = Field(4), minute = Field(5), second = Field(6);
        if (year < 1 || month is < 1 or > 12 || day < 1 || minute > 59 || second > 59) return null;
        if (lenient ? day > 31 || hour > 24 : day > DateTime.DaysInMonth(year, month) || hour > 23) return null;
        var milliseconds = match.Groups[7].Success ? int.Parse((match.Groups[7].Value + "00")[..3], CultureInfo.InvariantCulture) : 0;
        try
        {
            var value = new DateTime(year, month, 1, 0, 0, 0, DateTimeKind.Unspecified)
                .AddDays(day - 1).AddHours(hour).AddMinutes(minute).AddSeconds(second).AddMilliseconds(milliseconds);
            return value;
        }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}
