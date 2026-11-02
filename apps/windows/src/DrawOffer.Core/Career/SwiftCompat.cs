using System.Text.Json.Nodes;
using System.Globalization;
using System.Numerics;
using System.Text;

namespace DrawOffer.Core.Models;

/// <summary>
/// 求职进度批次共用的 Swift 语义复刻：字符（grapheme）计数与前缀、Foundation 字符集裁剪、
/// `Character.isNumber`、Swift 字符串排序、`localizedStandardCompare`、`.rounded()` 与 `%.1f`。
/// </summary>
internal static class SwiftText
{
    /// <summary>字符串的扩展字形簇（Swift `Character`）。</summary>
    public static string[] Elements(string value)
    {
        var result = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(value);
        while (e.MoveNext()) result.Add((string)e.Current);
        return result.ToArray();
    }

    /// <summary>`String.count`。</summary>
    public static int Count(string value) => new StringInfo(value).LengthInTextElements;

    static HashSet<int> Boundaries(string value)
    {
        var set = new HashSet<int>(StringInfo.ParseCombiningCharacters(value)) { value.Length };
        return set;
    }

    /// <summary>`hasPrefix`：按字形边界比较（"é" 不以 "e" 开头）。</summary>
    public static bool HasPrefix(string value, string prefix)
    {
        if (prefix.Length == 0) return true;
        if (!value.StartsWith(prefix, StringComparison.Ordinal)) return false;
        return value.Length == prefix.Length || Boundaries(value).Contains(prefix.Length);
    }

    /// <summary>`contains(String)`：命中位置两端都要落在字形边界上。</summary>
    public static bool Contains(string value, string needle)
    {
        if (needle.Length == 0) return true;
        var index = value.IndexOf(needle, StringComparison.Ordinal);
        if (index < 0) return false;
        var bounds = Boundaries(value);
        for (; index >= 0; index = value.IndexOf(needle, index + 1, StringComparison.Ordinal))
            if (bounds.Contains(index) && bounds.Contains(index + needle.Length)) return true;
        return false;
    }

    /// <summary>`dropFirst(n)`（按字符）。</summary>
    public static string DropFirst(string value, int count) => string.Concat(Elements(value).Skip(count));

    /// <summary>`prefix(n)`（按字符）。</summary>
    public static string Prefix(string value, int count) => string.Concat(Elements(value).Take(count));

    /// <summary>`CharacterSet.whitespaces`：Zs 与制表符。</summary>
    public static bool IsWhitespaceScalar(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// <summary>`CharacterSet.newlines`：U+000A–U+000D、U+0085、U+2028、U+2029。</summary>
    public static bool IsNewlineScalar(char c) => c is >= '\n' and <= '\r' or '\u0085' or '\u2028' or '\u2029';

    /// <summary>`trimmingCharacters(in: .whitespaces)`。</summary>
    public static string TrimWhitespaces(string value) => Trim(value, IsWhitespaceScalar);

    /// <summary>`trimmingCharacters(in: .newlines)`。</summary>
    public static string TrimNewlines(string value) => Trim(value, IsNewlineScalar);

    /// <summary>`trimmingCharacters(in: .whitespacesAndNewlines)`：与 `char.IsWhiteSpace` 的集合相同。</summary>
    public static string TrimAll(string value) => value.Trim();

    static string Trim(string value, Func<char, bool> drop)
    {
        int start = 0, end = value.Length;
        while (start < end && drop(value[start])) start++;
        while (end > start && drop(value[end - 1])) end--;
        return value[start..end];
    }

    /// <summary>`Character.isWhitespace`：首个标量具有 White_Space 属性。</summary>
    public static bool IsWhitespace(string character) => character.Length > 0 && char.IsWhiteSpace(character, 0);

    // 具有 Numeric_Type 但不属于 N* 类别的码位（CJK 数字等），由 Swift 逐码位枚举得出。
    static readonly HashSet<int> NumericIdeographs = [
        0x3405, 0x3483, 0x382A, 0x3B4D, 0x4E00, 0x4E03, 0x4E07, 0x4E09, 0x4E24, 0x4E5D, 0x4E8C, 0x4E94, 0x4E96, 0x4EAC, 0x4EBF, 0x4EC0,
        0x4EDF, 0x4EE8, 0x4F0D, 0x4F70, 0x4FE9, 0x5006, 0x5104, 0x5146, 0x5169, 0x516B, 0x516D, 0x5341, 0x5343, 0x5344, 0x5345, 0x534C,
        0x53C1, 0x53C2, 0x53C3, 0x53C4, 0x56DB, 0x58F1, 0x58F9, 0x5E7A, 0x5EFE, 0x5EFF, 0x5F0C, 0x5F0D, 0x5F0E, 0x5F10, 0x62D0, 0x62FE,
        0x634C, 0x67D2, 0x6D1E, 0x6F06, 0x7396, 0x767E, 0x7695, 0x79ED, 0x8086, 0x842C, 0x8CAE, 0x8CB3, 0x8D30, 0x920E, 0x94A9, 0x9621,
        0x9646, 0x964C, 0x9678, 0x96F6, 0xF96B, 0xF973, 0xF978, 0xF9B2, 0xF9D1, 0xF9D3, 0xF9FD, 0x12038, 0x12039, 0x12079, 0x12226,
        0x1222B, 0x1230B, 0x1230D, 0x12399, 0x20001, 0x20064, 0x200E2, 0x20121, 0x2092A, 0x20983, 0x2098C, 0x2099C, 0x20AEA, 0x20AFD,
        0x20B19, 0x22390, 0x22998, 0x23B1B, 0x2626D, 0x2F890,
    ];

    /// <summary>`Character.isNumber`：首个标量有 Numeric_Type（包括“一”“十”“两”等汉字数字）。</summary>
    public static bool IsNumber(string character)
    {
        if (character.Length == 0) return false;
        var rune = Rune.GetRuneAt(character, 0);
        return Rune.GetUnicodeCategory(rune) is UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber
            || NumericIdeographs.Contains(rune.Value);
    }

    /// <summary>Swift `String` 的 `&lt;`：NFC 后按 Unicode 标量比较。</summary>
    public static int Compare(string left, string right)
    {
        var a = left.Normalize(NormalizationForm.FormC).EnumerateRunes().GetEnumerator();
        var b = right.Normalize(NormalizationForm.FormC).EnumerateRunes().GetEnumerator();
        while (true)
        {
            bool hasA = a.MoveNext(), hasB = b.MoveNext();
            if (!hasA || !hasB) return hasA == hasB ? 0 : hasA ? 1 : -1;
            if (a.Current.Value != b.Current.Value) return a.Current.Value < b.Current.Value ? -1 : 1;
        }
    }

    public static readonly IComparer<string> Ordering = Comparer<string>.Create(Compare);

    /// <summary>`localizedStandardCompare`：数字按数值、忽略大小写差异的本地化比较（ICU 数字排序）。</summary>
    public static int StandardCompare(string left, string right)
    {
        var result = CultureInfo.InvariantCulture.CompareInfo.Compare(left, right, CompareOptions.NumericOrdering);
        if (result != 0) return result;
        // ICU 认为相等时（"007" 与 "7"、"12" 与 "１２"），Foundation 仍分先后：短的在前，再按码元。
        if (left.Length != right.Length) return left.Length < right.Length ? -1 : 1;
        return Math.Sign(string.CompareOrdinal(left, right));
    }

    /// <summary>Swift `Double.rounded()`：四舍五入，0.5 远离零。</summary>
    public static double Rounded(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    /// <summary>`String(format: "%.1f", value)`：按二进制精确值四舍六入五成双。</summary>
    public static string Fixed1(double value)
    {
        if (double.IsNaN(value)) return "nan";
        if (double.IsInfinity(value)) return value > 0 ? "inf" : "-inf";
        var bits = BitConverter.DoubleToInt64Bits(value);
        var negative = bits < 0;
        var exponent = (int)((bits >> 52) & 0x7FF);
        var mantissa = bits & 0xFFFFFFFFFFFFFL;
        if (exponent == 0) exponent = 1; else mantissa |= 1L << 52;
        exponent -= 1075;
        BigInteger numerator = new BigInteger(mantissa) * 10, denominator = BigInteger.One;
        if (exponent > 0) numerator <<= exponent; else denominator <<= -exponent;
        var quotient = BigInteger.DivRem(numerator, denominator, out var remainder);
        var twice = remainder * 2;
        if (twice > denominator || twice == denominator && !quotient.IsEven) quotient += 1;
        var digits = quotient.ToString(CultureInfo.InvariantCulture).PadLeft(2, '0');
        var text = digits[..^1] + "." + digits[^1];
        return (negative && quotient != 0 ? "-" : negative ? "-" : "") + text;
    }

    /// <summary>`("lo"..."hi").contains(value)`：按 Swift 字符串顺序的闭区间。</summary>
    public static bool InRange(string value, string low, string high) => Compare(low, value) <= 0 && Compare(value, high) <= 0;

    /// <summary>Mac 私有扩展 `nonempty(_:)` / `nonEmpty(_:)`：空串时取替代值。</summary>
    public static string Or(this string value, string fallback) => value.Length == 0 ? fallback : value;

    /// <summary>`lowercased()`：与 Swift 全量小写的差别只在 U+0130（Swift 得到两个标量），本批次的比较不涉及。</summary>
    public static string Lower(string value) => value.ToLowerInvariant();

    /// <summary>`split(whereSeparator:)`（省略空段），按字符。</summary>
    public static string[] Split(string value, Func<string, bool> separator)
    {
        var parts = new List<string>(); var current = new StringBuilder();
        foreach (var element in Elements(value))
        {
            if (separator(element)) { if (current.Length > 0) parts.Add(current.ToString()); current.Clear(); }
            else current.Append(element);
        }
        if (current.Length > 0) parts.Add(current.ToString());
        return parts.ToArray();
    }

    /// <summary>`drop(while:)`：去掉开头满足条件的字符。</summary>
    public static string DropWhile(string value, Func<string, bool> predicate) => string.Concat(Elements(value).SkipWhile(predicate));

    /// <summary>`Int(String)`：可选正负号与 ASCII 数字，不允许空白。</summary>
    public static int? Int(string value) =>
        value.Length > 0 && int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number) ? number : null;
}

/// <summary>
/// 以 <see cref="TimeZoneInfo"/> 复刻 Swift 公历 `Calendar` 的日级运算：
/// 跳过的本地时间向后顺延、重复的本地时间按方向取值，`startOfDay` 取当天第一个时刻。
/// </summary>
internal static class SwiftCalendar
{
    public static DateTime Local(DateTimeOffset date, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(date, zone).DateTime;

    /// <summary>把本地墙钟时间换成时刻；不存在的时间顺延跳过的时长，重复的时间 <paramref name="earlier"/> 为真取较早一次。</summary>
    public static DateTimeOffset Resolve(DateTime local, TimeZoneInfo zone, bool earlier = true)
    {
        local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        if (zone.IsInvalidTime(local))
        {
            // 跳过的时段：Swift 把墙钟时间顺延跳过的时长（例如 00:00 → 01:00）。
            var before = zone.GetUtcOffset(local.AddHours(-12));
            var after = zone.GetUtcOffset(local.AddHours(12));
            var shifted = local + (after - before);
            return new DateTimeOffset(shifted, zone.GetUtcOffset(shifted));
        }
        if (zone.IsAmbiguousTime(local))
        {
            var offsets = zone.GetAmbiguousTimeOffsets(local);
            var offset = earlier ? offsets.Max() : offsets.Min();
            return new DateTimeOffset(local, offset);
        }
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }

    /// <summary>`startOfDay(for:)`。</summary>
    public static DateTimeOffset StartOfDay(DateTimeOffset date, TimeZoneInfo zone) => Resolve(Local(date, zone).Date, zone);

    /// <summary>`date(byAdding: .day, value:)`：保留墙钟时间。</summary>
    public static DateTimeOffset AddDays(DateTimeOffset date, int days, TimeZoneInfo zone) => Resolve(Local(date, zone).AddDays(days), zone, earlier: days >= 0);

    /// <summary>`isDate(_:inSameDayAs:)`。</summary>
    public static bool SameDay(DateTimeOffset a, DateTimeOffset b, TimeZoneInfo zone) => Local(a, zone).Date == Local(b, zone).Date;

    /// <summary>`dateComponents([.day], from:to:).day`：不超过目标的整天数。</summary>
    public static int Days(DateTimeOffset from, DateTimeOffset to, TimeZoneInfo zone)
    {
        var n = (Local(to, zone).Date - Local(from, zone).Date).Days;
        if (to >= from)
        {
            while (n > 0 && AddDays(from, n, zone) > to) n--;
            while (AddDays(from, n + 1, zone) <= to) n++;
        }
        else
        {
            while (n < 0 && AddDays(from, n, zone) < to) n++;
            while (AddDays(from, n - 1, zone) >= to) n--;
        }
        return n;
    }

    /// <summary>`component(.weekday)`：周日为 1。</summary>
    public static int Weekday(DateTimeOffset date, TimeZoneInfo zone) => (int)Local(date, zone).DayOfWeek + 1;

    /// <summary>`date(from: DateComponents(year:month:day:))`；越界日期返回 null（调用方会复核）。</summary>
    public static DateTimeOffset? Date(int year, int month, int day, TimeZoneInfo zone)
    {
        if (year < 1 || year > 9999) return null;
        try
        {
            var local = new DateTime(year, 1, 1).AddMonths(month - 1).AddDays(day - 1);
            return Resolve(local, zone);
        }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}

/// <summary>
/// `Data(base64Encoded:)`（默认选项）：不接受空白和非字母表字符，长度须为 4 的倍数。
/// 标准编码与 Foundation 一致；Foundation 还会接受少数畸形填充（如 `AA=A`），这里不接受。
/// </summary>
internal static class SwiftBase64
{
    public static byte[]? Decode(string text)
    {
        if (text.Any(c => char.IsWhiteSpace(c))) return null;
        var buffer = new byte[text.Length * 3 / 4 + 3];
        return Convert.TryFromBase64String(text, buffer, out var written) ? buffer[..written] : null;
    }
}

/// <summary>JSON 与集合的 Swift 语义小工具。</summary>
internal static class CareerJson
{
    /// <summary>Swift 5 的 `sorted(by:)` 是稳定排序：相等元素保持原顺序。</summary>
    public static List<T> StableSort<T>(IEnumerable<T> items, Comparison<T> comparison) =>
        items.Select((item, index) => (item, index)).OrderBy(x => x, Comparer<(T item, int index)>.Create((a, b) => comparison(a.item, b.item) is var c && c != 0 ? c : a.index.CompareTo(b.index))).Select(x => x.item).ToList();

    /// <summary>`json?.integer == value`：数字截断取整后相等（缺失为 nil，不相等）。</summary>
    public static bool IsInteger(JsonNode? node, int value) => node.Number() is { } number && (int)number == value;

    /// <summary>`json[key]?.integer`：键不存在为 null；存在时非数字（含 JSON null）为 0，数字截断取整。</summary>
    public static int? OptionalInteger(JsonNode? node, string key) =>
        node is JsonObject obj && obj.TryGetPropertyValue(key, out var value) ? value.Number() is { } number ? (int)number : 0 : null;

    /// <summary>`json[key]?.stringValue`。</summary>
    public static string? OptionalString(JsonNode? node, string key) => node.Get(key).String();

    /// <summary>`items.compactMap(\.stringValue)`。</summary>
    public static List<string> Strings(JsonNode? node) => node.Items().Select(x => x.String()).OfType<string>().ToList();
}

/// <summary>`Date.distantPast` / `Date.distantFuture`。</summary>
internal static class SwiftDates
{
    public static readonly DateTimeOffset DistantPast = new(1, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public static readonly DateTimeOffset DistantFuture = new(4001, 1, 1, 0, 0, 0, TimeSpan.Zero);
}

/// <summary>
/// `URLComponents(string:)` 对相对引用的取值：scheme、host、fragment 是否存在，解码后的 path 与 queryItems。
/// 只覆盖 Logo 校验需要的部分；按 Foundation 规则，含无效百分号编码的部分保持原样。
/// </summary>
internal sealed record RelativeUrl(string Path, IReadOnlyList<(string Name, string? Value)> Query)
{
    public static RelativeUrl? Parse(string text)
    {
        if (text.Contains('#') || text.StartsWith("//", StringComparison.Ordinal)) return null;
        var end = text.IndexOfAny(['/', '?']);
        var head = end < 0 ? text : text[..end];
        // 有 scheme（`a:b`）或首段带冒号（URLComponents 返回 nil）都不是本站相对路径。
        if (head.Contains(':')) return null;
        var question = text.IndexOf('?');
        var path = Decode(question < 0 ? text : text[..question]);
        var items = new List<(string, string?)>();
        if (question >= 0)
        {
            var query = text[(question + 1)..];
            if (query.Length > 0)
                foreach (var part in query.Split('&'))
                {
                    var equals = part.IndexOf('=');
                    items.Add(equals < 0 ? (Decode(part), null) : (Decode(part[..equals]), Decode(part[(equals + 1)..])));
                }
        }
        return new RelativeUrl(path, items);
    }

    /// <summary>`removingPercentEncoding ?? 原文`。</summary>
    static string Decode(string value)
    {
        if (!value.Contains('%')) return value;
        var bytes = new List<byte>();
        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] != '%')
            {
                var next = value.IndexOf('%', i);
                var run = next < 0 ? value[i..] : value[i..next];
                bytes.AddRange(Encoding.UTF8.GetBytes(run)); i += run.Length - 1; continue;
            }
            if (i + 2 >= value.Length || !Uri.IsHexDigit(value[i + 1]) || !Uri.IsHexDigit(value[i + 2])) return value;
            bytes.Add(Convert.ToByte(value.Substring(i + 1, 2), 16)); i += 2;
        }
        try { return new UTF8Encoding(false, true).GetString(bytes.ToArray()); }
        catch (DecoderFallbackException) { return value; }
    }
}
