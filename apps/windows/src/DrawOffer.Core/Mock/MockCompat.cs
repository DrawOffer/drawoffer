using System.Globalization;
using System.Text;

namespace DrawOffer.Core.Models;

/// <summary>模拟面试沿用 Career 的 Swift 字符语义；UTF-16 截断按 Foundation 修复孤立代理项。</summary>
internal static class MockText
{
    public static string[] Graphemes(string text) => SwiftText.Elements(text);
    public static int Count(string text) => SwiftText.Count(text);
    public static string Prefix(string text, int count) => SwiftText.Prefix(text, count);
    public static bool IsWhitespace(string text) => SwiftText.IsWhitespace(text);
    public static bool Contains(string text, string part) => SwiftText.Contains(text.Normalize(NormalizationForm.FormC), part.Normalize(NormalizationForm.FormC));
    public static string Lower(string text) => text.Replace("İ", "i̇", StringComparison.Ordinal).ToLowerInvariant();
    public static (int Start, int End)? Range(string text, string quote)
    {
        var parts = SwiftText.Elements(text); var target = quote.Normalize(NormalizationForm.FormC); var offset = 0;
        for (var i = 0; i < parts.Length; i++)
        {
            var candidate = "";
            for (var j = i; j < parts.Length; j++)
            {
                candidate += parts[j]; var normalized = candidate.Normalize(NormalizationForm.FormC);
                if (normalized == target) return (offset, offset + candidate.Length);
                if (normalized.Length > target.Length) break;
            }
            offset += parts[i].Length;
        }
        return null;
    }
    public static string TrimSpaces(string text) => SwiftText.TrimWhitespaces(text);
    public static string CollapseWhitespace(string text) => string.Join(" ", SwiftText.Split(text, SwiftText.IsWhitespace));
    public static IComparer<string> Order => SwiftText.Ordering;
    public static bool Less(string a, string b) => SwiftText.Compare(a, b) < 0;
    public static int Int(double value) => (int)value;
    public static string FromUtf16(ReadOnlySpan<char> chars) => string.Concat(chars.ToString().EnumerateRunes().Select(r => r.ToString()));
    public static double? SwiftDouble(string text) => text.Length > 0 && text == text.Trim() && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;
    public static string SwiftString(double value) => value.ToString("R", CultureInfo.InvariantCulture);
}
