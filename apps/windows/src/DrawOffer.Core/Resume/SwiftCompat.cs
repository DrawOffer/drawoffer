using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("DrawOffer.Core.Tests")]

namespace DrawOffer.Core.Models;

/// <summary>
/// 首页、AI 对话与简历批次移植用到的 Swift / Foundation 语义：字素计数与截取、`CharacterSet` 修剪、
/// NSString 风格的 `contains`、NSRegularExpression（ICU）的 `.` 与 `$`、ISO8601DateFormatter、Calendar 换日与 JSONValue 比较。
/// 只供本程序集内部使用，行为以在 macOS 上实测的 Swift 结果为准。
/// </summary>
internal static class SwiftCompat
{
    // MARK: 字符集

    /// <summary>`CharacterSet.whitespaces`：Unicode Zs 与 TAB。</summary>
    public static bool IsWhitespace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// <summary>`CharacterSet.newlines`：U+000A–U+000D、U+0085、U+2028、U+2029。</summary>
    public static bool IsNewline(char c) => c is '\n' or '\v' or '\f' or '\r' or '\u0085' or (char)0x2028 or (char)0x2029;

    /// <summary>`trimmingCharacters(in: .whitespaces)`。</summary>
    public static string TrimWs(string s) => Trim(s, IsWhitespace);

    /// <summary>`trimmingCharacters(in: .whitespacesAndNewlines)`。</summary>
    public static string Trimmed(string s) => Trim(s, c => IsWhitespace(c) || IsNewline(c));

    static string Trim(string s, Func<char, bool> drop)
    {
        int start = 0, end = s.Length;
        while (start < end && drop(s[start])) start++;
        while (end > start && drop(s[end - 1])) end--;
        return start == 0 && end == s.Length ? s : s[start..end];
    }

    /// <summary>Swift `nilIfBlank`：修剪后为空时为 null，否则返回原串（不修剪）。</summary>
    public static string? NilIfBlank(string s) => Trimmed(s).Length == 0 ? null : s;

    /// <summary>`Character.isWhitespace`：字素首个标量具有 Unicode White_Space 属性。</summary>
    public static bool IsWhitespaceScalar(int value) => value is >= 0x09 and <= 0x0D or 0x20 or 0x85 or 0xA0 or 0x1680 or >= 0x2000 and <= 0x200A
        or 0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000;

    // MARK: 字素（Swift Character）

    /// <summary>字符串的扩展字素簇。</summary>
    public static IEnumerable<string> Graphemes(string s)
    {
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) yield return (string)e.Current;
    }

    /// <summary>`String.count`。</summary>
    public static int Count(string s) => s.Length == 0 ? 0 : new StringInfo(s).LengthInTextElements;

    /// <summary>`String(s.prefix(n))`：按字素截取。</summary>
    public static string Prefix(string s, int n)
    {
        if (n <= 0) return "";
        var e = StringInfo.GetTextElementEnumerator(s);
        var taken = 0;
        while (e.MoveNext())
        {
            if (taken == n) return s[..e.ElementIndex];
            taken++;
        }
        return s;
    }

    /// <summary>`String(s.dropFirst(n))`：按字素去掉开头。</summary>
    public static string DropFirst(string s, int n)
    {
        if (n <= 0) return s;
        var e = StringInfo.GetTextElementEnumerator(s);
        var dropped = 0;
        while (e.MoveNext())
        {
            if (dropped == n) return s[e.ElementIndex..];
            dropped++;
        }
        return "";
    }

    /// <summary>字素数与 Swift 相同的“非空白字符数”：`s.filter { !$0.isWhitespace }.count`。</summary>
    public static int CountNonWhitespace(string s) => Graphemes(s).Count(g => !IsWhitespaceScalar(char.ConvertToUtf32(g, 0)));

    static HashSet<int> Boundaries(string s)
    {
        var set = new HashSet<int> { s.Length };
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) set.Add(e.ElementIndex);
        return set;
    }

    /// <summary>
    /// Swift（导入 Foundation 后）`hay.contains(needle)`：空串永远不包含；匹配的首尾都必须落在字素边界上
    /// （所以 `"a\r\nb".contains("\n")` 为 false）。
    /// </summary>
    public static bool Has(string hay, string needle)
    {
        if (needle.Length == 0 || hay.Length < needle.Length) return false;
        HashSet<int>? bounds = null;
        for (var at = hay.IndexOf(needle, StringComparison.Ordinal); at >= 0; at = hay.IndexOf(needle, at + 1, StringComparison.Ordinal))
        {
            bounds ??= Boundaries(hay);
            if (bounds.Contains(at) && bounds.Contains(at + needle.Length)) return true;
        }
        return false;
    }

    /// <summary>Swift `split(separator:)` / `split(whereSeparator:)`：按字素切分，`"\r\n"` 不等于 `"\n"`。</summary>
    public static List<string> SplitCharacters(string s, string separators, bool omitEmpty = true)
    {
        var parts = new List<string>();
        var current = new StringBuilder();
        foreach (var g in Graphemes(s))
        {
            if (g.Length == 1 && separators.Contains(g[0]))
            {
                if (!omitEmpty || current.Length > 0) parts.Add(current.ToString());
                current.Clear();
            }
            else current.Append(g);
        }
        if (!omitEmpty || current.Length > 0) parts.Add(current.ToString());
        return parts;
    }

    /// <summary>Swift `Int(String)`：可选正负号加 ASCII 数字，不允许空白，超出 Int64 为 null。</summary>
    public static long? Int(string s)
    {
        var digits = s.Length > 0 && s[0] is '+' or '-' ? s[1..] : s;
        if (digits.Length == 0 || !digits.All(char.IsAsciiDigit)) return null;
        return long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    /// <summary>Swift `Double(String)`，只用于正则分组里的数字（非 ASCII 数字为 null）。</summary>
    public static double? DoubleDigits(string s) =>
        s.Length > 0 && s.All(char.IsAsciiDigit) ? double.Parse(s, CultureInfo.InvariantCulture) : null;

    /// <summary>Swift `Double.description`：整数值在 1e16 以内带 `.0`，其余用最短往返表示与小写指数。</summary>
    public static string DoubleText(double value)
    {
        if (double.IsNaN(value)) return "nan";
        if (double.IsInfinity(value)) return value > 0 ? "inf" : "-inf";
        if (value == Math.Floor(value) && Math.Abs(value) < 1e16) return ((long)value).ToString(CultureInfo.InvariantCulture) + ".0";
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        var e = text.IndexOf('E');
        if (e < 0) return text;
        var mantissa = text[..e];
        var exponent = int.Parse(text[(e + 1)..], CultureInfo.InvariantCulture);
        return mantissa + "e" + (exponent < 0 ? "-" : "+") + Math.Abs(exponent).ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>Swift `rounded()`：四舍五入，0.5 远离零。</summary>
    public static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    // MARK: 正则（NSRegularExpression / ICU）

    /// <summary>ICU 的 `.`：不匹配任何行终止符（.NET 的 `.` 会匹配 `\r`）。</summary>
    public const string Dot = @"[^\n\v\f\r\u0085\u2028\u2029]";

    /// <summary>ICU 未开多行时的 `$`：文本末尾，或末尾唯一一个行终止符之前。</summary>
    public const string End = @"(?=(?:\r\n|[\n\v\f\r\u0085\u2028\u2029])?\z)";

    static readonly ConcurrentDictionary<(string, bool), Regex> Cache = new();

    /// <summary>编译并缓存正则；`ignoreCase` 对应 `.caseInsensitive`。`^` 不开多行（与 NSRegularExpression 默认一致）。</summary>
    public static Regex Re(string pattern, bool ignoreCase = false) =>
        Cache.GetOrAdd((pattern, ignoreCase), key => new Regex(key.Item1, RegexOptions.CultureInvariant | (key.Item2 ? RegexOptions.IgnoreCase : RegexOptions.None)));

    /// <summary>`text.range(of: pattern, options: .regularExpression) != nil`。</summary>
    public static bool Matches(string pattern, string text, bool ignoreCase = false) => Re(pattern, ignoreCase).IsMatch(text);

    /// <summary>第一处匹配的全部分组；未参与匹配的分组为空串。</summary>
    public static string[]? Groups(Regex regex, string text)
    {
        var match = regex.Match(text);
        if (!match.Success) return null;
        return match.Groups.Cast<Group>().Select(g => g.Success ? g.Value : "").ToArray();
    }

    /// <summary>`replacingOccurrences(of: pattern, with:, options: .regularExpression)`。</summary>
    public static string Replace(string text, string pattern, string replacement, bool ignoreCase = false) => Re(pattern, ignoreCase).Replace(text, replacement);

    /// <summary>按正则切开，保留空段（Mac `split(_:by:)`）。</summary>
    public static List<string> SplitRegex(string text, Regex regex)
    {
        var parts = new List<string>();
        var last = 0;
        foreach (Match match in regex.Matches(text))
        {
            parts.Add(text[last..match.Index]);
            last = match.Index + match.Length;
        }
        parts.Add(text[last..]);
        return parts;
    }

    // MARK: 日期

    /// <summary>
    /// `Date.distantPast` / `distantFuture` 的替身（只用于比较与兜底）。比 DateTimeOffset 的极值各留两天，
    /// 换算到任意时区或取当天零点时不会越界。
    /// </summary>
    public static readonly DateTimeOffset DistantPast = DateTimeOffset.MinValue.AddDays(2);
    public static readonly DateTimeOffset DistantFuture = DateTimeOffset.MaxValue.AddDays(-2);

    static readonly Regex IsoPattern = new(@"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})(?:\.([0-9]+))?(Z|z|([+-])([0-9]{1,2})(?::?([0-9]{1,2}))?)$", RegexOptions.CultureInvariant);
    static readonly Regex LocalPattern = new(@"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})(?:\.([0-9]{1,9}))?[ \t]*$", RegexOptions.CultureInvariant);

    /// <summary>
    /// `ISO8601DateFormatter`：`fractional` 为 true 时（`.withFractionalSeconds`）必须带小数秒，否则不能带。
    /// 与 Apple 相同：小数截到毫秒，日超出当月时顺延（2 月 30 日 → 3 月 2 日），24 点视为次日零点，月份 13、分秒 60 无效。
    /// </summary>
    public static DateTimeOffset? Iso(string text, bool fractional)
    {
        var m = IsoPattern.Match(text);
        if (!m.Success || m.Groups[7].Success != fractional) return null;
        int year = int.Parse(m.Groups[1].Value), month = int.Parse(m.Groups[2].Value), day = int.Parse(m.Groups[3].Value);
        int hour = int.Parse(m.Groups[4].Value), minute = int.Parse(m.Groups[5].Value), second = int.Parse(m.Groups[6].Value);
        if (year < 1 || month is < 1 or > 12 || day is < 1 or > 31 || hour > 24 || minute > 59 || second > 59) return null;
        var offset = TimeSpan.Zero;
        if (m.Groups[9].Success)
        {
            int oh = int.Parse(m.Groups[10].Value), om = m.Groups[11].Success ? int.Parse(m.Groups[11].Value) : 0;
            if (om > 59 || oh > 24) return null;
            offset = TimeSpan.FromMinutes((oh * 60 + om) * (m.Groups[9].Value == "-" ? -1 : 1));
        }
        try
        {
            var local = new DateTime(year, month, 1).AddDays(day - 1).AddHours(hour).AddMinutes(minute).AddSeconds(second)
                .AddMilliseconds(Milliseconds(m.Groups[7].Value));
            return new DateTimeOffset(local.Ticks - offset.Ticks, TimeSpan.Zero);
        }
        catch (ArgumentOutOfRangeException) { return null; }
    }

    static int Milliseconds(string fraction) => fraction.Length == 0 ? 0 : int.Parse((fraction + "00")[..3], CultureInfo.InvariantCulture);

    /// <summary>Mac `ResumeSummary.parseTimestamp`：后端不带时区的时间按 UTC 读；带或不带小数秒都接受。</summary>
    public static DateTimeOffset? ParseTimestamp(string value)
    {
        var hasZone = value.EndsWith('Z') || Re(@"[+-]\d{2}:\d{2}" + End).IsMatch(value);
        var text = hasZone ? value : value + "Z";
        return Iso(text, true) ?? Iso(text, false);
    }

    /// <summary>
    /// Mac `CareerApplication.date`：先按 ISO 8601（带或不带小数秒）读；不带时区的
    /// `yyyy-MM-dd'T'HH:mm:ss[.S…]` 按 `zone` 本地时间读（DateFormatter：日期必须有效，小数截到毫秒）。
    /// </summary>
    public static DateTimeOffset? CareerDate(string text, TimeZoneInfo zone)
    {
        if ((Iso(text, true) ?? Iso(text, false)) is { } date) return date;
        var m = LocalPattern.Match(text);
        if (!m.Success) return null;
        int year = int.Parse(m.Groups[1].Value), month = int.Parse(m.Groups[2].Value), day = int.Parse(m.Groups[3].Value);
        int hour = int.Parse(m.Groups[4].Value), minute = int.Parse(m.Groups[5].Value), second = int.Parse(m.Groups[6].Value);
        if (year < 1 || month is < 1 or > 12 || day < 1 || day > DateTime.DaysInMonth(year, month) || hour > 23 || minute > 59 || second > 59) return null;
        return FromLocal(new DateTime(year, month, day, hour, minute, second).AddMilliseconds(Milliseconds(m.Groups[7].Value)), zone);
    }

    /// <summary>某一时刻在 `zone` 的墙上时间。</summary>
    public static DateTime Local(DateTimeOffset date, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(date, zone).DateTime;

    /// <summary>
    /// 墙上时间 → 时刻（Calendar 的规则）：夏令时跳过的时刻按跳变前的偏移换算（等于往后顺延），
    /// 重复的时刻取较早的一次。
    /// </summary>
    public static DateTimeOffset FromLocal(DateTime local, TimeZoneInfo zone)
    {
        local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
        TimeSpan offset;
        if (zone.IsInvalidTime(local)) offset = zone.GetUtcOffset(local.AddHours(-3));
        else if (zone.IsAmbiguousTime(local)) offset = zone.GetAmbiguousTimeOffsets(local).Max();
        else offset = zone.GetUtcOffset(local);
        return new DateTimeOffset(local.Ticks - offset.Ticks, TimeSpan.Zero);
    }

    /// <summary>`calendar.startOfDay(for:)`。</summary>
    public static DateTimeOffset StartOfDay(DateTimeOffset date, TimeZoneInfo zone) => FromLocal(Local(date, zone).Date, zone);

    /// <summary>`calendar.date(from: DateComponents(year:month:day:hour:))`：分量超出范围时顺延换算；无法表示时为 null。</summary>
    public static DateTimeOffset? FromComponents(long year, long month, long day, int hour, TimeZoneInfo zone)
    {
        try
        {
            if (year is < 1 or > 9999) return null;
            var local = new DateTime((int)year, 1, 1).AddMonths(checked((int)(month - 1))).AddDays(day - 1).AddHours(hour);
            return FromLocal(local, zone);
        }
        catch (Exception e) when (e is ArgumentOutOfRangeException or OverflowException) { return null; }
    }

    /// <summary>`a.timeIntervalSince(b)`（秒）。</summary>
    public static double Since(DateTimeOffset a, DateTimeOffset b) => (a.UtcTicks - b.UtcTicks) / (double)TimeSpan.TicksPerSecond;

    /// <summary>`date.addingTimeInterval(seconds)`。</summary>
    public static DateTimeOffset Adding(DateTimeOffset date, double seconds) => date.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));

    /// <summary>`timeIntervalSince1970`。</summary>
    public static double Epoch(DateTimeOffset date) => Since(date, DateTimeOffset.UnixEpoch);

    // MARK: 序列

    /// <summary>Swift `max(by:)`：并列时保留最先出现的。</summary>
    public static T? MaxBy<T>(IEnumerable<T> items, Func<T, T, bool> less) where T : class
    {
        T? result = null;
        foreach (var item in items) if (result is null || less(result, item)) result = item;
        return result;
    }

    /// <summary>Swift `min(by:)`：并列时保留最先出现的。</summary>
    public static T? MinBy<T>(IEnumerable<T> items, Func<T, T, bool> less) where T : class
    {
        T? result = null;
        foreach (var item in items) if (result is null || less(item, result)) result = item;
        return result;
    }

    /// <summary>Swift `min(x, y)`：`y &lt; x ? y : x`（与 Math.Min 对 NaN 的处理不同）。</summary>
    public static double Min(double x, double y) => y < x ? y : x;

    /// <summary>Swift `max(x, y)`：`y &gt;= x ? y : x`。</summary>
    public static double Max(double x, double y) => y >= x ? y : x;

    /// <summary>Swift `Sequence.min()`：逐个用 `&lt;` 比较，保留最先的最小值。</summary>
    public static double Least(IEnumerable<double> values)
    {
        using var e = values.GetEnumerator();
        if (!e.MoveNext()) throw new InvalidOperationException("empty sequence");
        var result = e.Current;
        while (e.MoveNext()) if (e.Current < result) result = e.Current;
        return result;
    }

    /// <summary>Swift `Sequence.max()`。</summary>
    public static double Most(IEnumerable<double> values)
    {
        using var e = values.GetEnumerator();
        if (!e.MoveNext()) throw new InvalidOperationException("empty sequence");
        var result = e.Current;
        while (e.MoveNext()) if (result < e.Current) result = e.Current;
        return result;
    }

    /// <summary>Swift `hasPrefix`：按字素比较，前缀必须结束在字素边界上；空前缀永远为 true。</summary>
    public static bool HasPrefix(string s, string prefix) =>
        prefix.Length == 0 || s.StartsWith(prefix, StringComparison.Ordinal) && (s.Length == prefix.Length || Boundaries(s).Contains(prefix.Length));

    /// <summary>
    /// Swift `String &lt;`：先做 NFC 规范化，再逐个比较 Unicode 标量值（不是 UTF-16 码元）。
    /// </summary>
    public static int Cmp(string a, string b)
    {
        if (ReferenceEquals(a, b)) return 0;
        var x = a.IsNormalized(NormalizationForm.FormC) ? a : a.Normalize(NormalizationForm.FormC);
        var y = b.IsNormalized(NormalizationForm.FormC) ? b : b.Normalize(NormalizationForm.FormC);
        var ex = x.EnumerateRunes();
        var ey = y.EnumerateRunes();
        while (true)
        {
            var hx = ex.MoveNext();
            var hy = ey.MoveNext();
            if (!hx || !hy) return hx == hy ? 0 : hx ? 1 : -1;
            var d = ex.Current.Value.CompareTo(ey.Current.Value);
            if (d != 0) return d;
        }
    }

    /// <summary>以 <see cref="Cmp"/> 排序的比较器（Swift `sorted()` 对字符串数组）。</summary>
    public static readonly IComparer<string> StringOrder = Comparer<string>.Create(Cmp);

    /// <summary>Swift `==` 对字符串：规范等价。</summary>
    public static bool Eq(string a, string b) => a == b || Cmp(a, b) == 0;

    /// <summary>Swift `.lowercased()`（Unicode 默认映射；与 Apple 的完整映射在少数特殊字母上可能不同）。</summary>
    public static string Lower(string s) => s.ToLowerInvariant();

    /// <summary>Swift `URL.appending(path:)` 的路径编码：保留 `urlPathAllowed`（含 `/`），其余按 UTF-8 百分号编码。</summary>
    public static string EscapePath(string path)
    {
        const string allowed = "!$&'()*+,-./:;=@_~";
        var builder = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(path))
        {
            var c = (char)b;
            if (b < 0x80 && (char.IsAsciiLetterOrDigit(c) || allowed.Contains(c))) builder.Append(c);
            else builder.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return builder.ToString();
    }

    // MARK: 错误（Swift APIError）

    /// <summary>Swift `APIError.unauthorized`：HTTP 层把所有 401 都转成它。</summary>
    public static bool IsUnauthorized(Exception error) => error is DrawOffer.Core.Api.ApiException { Status: System.Net.HttpStatusCode.Unauthorized };

    /// <summary>Swift `APIError.server(status, code)`：401 以外的服务端错误。</summary>
    public static bool IsServer(Exception error, out int status, out string code)
    {
        if (error is DrawOffer.Core.Api.ApiException api && api.Status != System.Net.HttpStatusCode.Unauthorized)
        {
            status = (int)api.Status; code = api.Code;
            return true;
        }
        status = 0; code = "";
        return false;
    }

    // MARK: JSON（Swift JSONValue）

    /// <summary>
    /// Swift `json.items`：保留数组里的 JSON null（Json.cs 的 `Items()` 会丢掉它们，计数与遍历会和 Mac 不同）。
    /// 不是数组时为空。
    /// </summary>
    public static List<JsonNode?> Arr(JsonNode? node) => node is JsonArray array ? array.ToList() : [];

    /// <summary>`json[key]?.items`：键不存在为 null，存在但不是数组为空表。</summary>
    public static List<JsonNode?>? ArrOpt(JsonNode? node, string key) => HasKey(node, key) ? Arr(node![key]) : null;

    /// <summary>对象里是否有这个键（值为 JSON null 也算有）。Swift `json[key] != nil`。</summary>
    public static bool HasKey(JsonNode? node, string key) => node is JsonObject obj && obj.ContainsKey(key);

    /// <summary>深拷贝；JsonNode 不能同时挂在两棵树上，写入前一律拷贝。</summary>
    public static JsonNode? Clone(JsonNode? node) => node?.DeepClone();

    /// <summary>Swift `JSONValue ==`：对象不看键序，数字按数值比较。</summary>
    public static bool Same(JsonNode? a, JsonNode? b) => JsonNode.DeepEquals(a, b);

    /// <summary>`.number(x)`：一律以 double 承载，避免 int 承载的值在 `GetValue&lt;double&gt;` 时抛异常。</summary>
    public static JsonValue Num(double value) => JsonValue.Create(value);

    /// <summary>`items.compactMap(\.stringValue)`。</summary>
    public static List<string> Strings(JsonNode? node) => node.Items().Select(x => x.String()).OfType<string>().ToList();

    /// <summary>拷贝出对象的字段；不是对象时为空对象（Swift `if case .object(var fields)` 的兜底）。</summary>
    public static JsonObject ObjectCopy(JsonNode? node) => node is JsonObject obj ? (JsonObject)obj.DeepClone() : new JsonObject();

    /// <summary>由节点序列组成数组（逐个深拷贝）。</summary>
    public static JsonArray Array(IEnumerable<JsonNode?> items)
    {
        var array = new JsonArray();
        foreach (var item in items) array.Add(Clone(item));
        return array;
    }

    /// <summary>字符串数组。</summary>
    public static JsonArray StringArray(IEnumerable<string> items) => new(items.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
}
