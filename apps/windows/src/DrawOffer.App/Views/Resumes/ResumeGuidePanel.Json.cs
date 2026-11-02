using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 引导面板用到的 Swift 语义小工具。Core 的 `SwiftCompat` 只对本程序集开放，这里照它的实现
/// 复制面板需要的几项：`trimmingCharacters(in: .whitespacesAndNewlines)`、字素计数与截取、Swift 字符串排序、
/// 保留 null 的 `json.items`，以及 `APIError` 的判断。
/// </summary>
static class GuideJson
{
    static bool IsWhitespace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
    static bool IsNewline(char c) => c is '\n' or '\v' or '\f' or '\r' or '\u0085' or (char)0x2028 or (char)0x2029;

    /// <summary>`trimmingCharacters(in: .whitespacesAndNewlines)`。</summary>
    public static string Trimmed(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && (IsWhitespace(s[start]) || IsNewline(s[start]))) start++;
        while (end > start && (IsWhitespace(s[end - 1]) || IsNewline(s[end - 1]))) end--;
        return s[start..end];
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

    /// <summary>Swift `String &lt;`：NFC 规范化后逐个比较 Unicode 标量（不是 UTF-16 码元）。</summary>
    public static int Cmp(string a, string b)
    {
        var ex = a.Normalize(NormalizationForm.FormC).EnumerateRunes();
        var ey = b.Normalize(NormalizationForm.FormC).EnumerateRunes();
        while (true)
        {
            bool hx = ex.MoveNext(), hy = ey.MoveNext();
            if (!hx || !hy) return hx == hy ? 0 : hx ? 1 : -1;
            var d = ex.Current.Value.CompareTo(ey.Current.Value);
            if (d != 0) return d;
        }
    }

    /// <summary>Swift `max(by:)`：并列时取最先出现的。</summary>
    public static T? MaxBy<T>(IEnumerable<T> items, Func<T, T, bool> less) where T : class
    {
        T? result = null;
        foreach (var item in items) if (result is null || less(result, item)) result = item;
        return result;
    }

    /// <summary>Swift `json.items`：保留数组里的 JSON null。</summary>
    public static List<JsonNode?> Arr(JsonNode? node) => node is JsonArray array ? array.ToList() : [];
    public static List<string> Strings(JsonNode? node) => node.Items().Select(x => x.String()).OfType<string>().ToList();
    public static JsonNode? Clone(JsonNode? node) => node?.DeepClone();
    public static JsonValue Num(double value) => JsonValue.Create(value);

    /// <summary>由节点序列组成数组（逐个深拷贝）。</summary>
    public static JsonArray Array(IEnumerable<JsonNode?> items)
    {
        var array = new JsonArray();
        foreach (var item in items) array.Add(Clone(item));
        return array;
    }

    public static JsonArray StringArray(IEnumerable<string> items) => new(items.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());

    /// <summary>Swift `APIError.unauthorized`。</summary>
    public static bool IsUnauthorized(Exception error) => error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized };

    /// <summary>Swift `APIError.server(status, code)`：401 以外的服务端错误。</summary>
    public static bool IsServer(Exception error, out int status, out string code)
    {
        if (error is ApiException api && api.Status != System.Net.HttpStatusCode.Unauthorized) { status = (int)api.Status; code = api.Code; return true; }
        status = 0;
        code = "";
        return false;
    }
}
