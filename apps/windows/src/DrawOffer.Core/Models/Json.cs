using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>
/// 与 Mac `JSONValue` 扩展同名同义的安全读取：类型不符时返回空值而不是抛异常（`GetValue&lt;string&gt;()` 遇到数字会抛）。
/// </summary>
public static class Json
{
    /// <summary>`json.text(key)`：只认字符串。</summary>
    public static string Text(this JsonNode? node, string key) => node is JsonObject obj && obj[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";

    /// <summary>`json.stringValue`。</summary>
    public static string? String(this JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    /// <summary>`json.display(key)`：字符串原样，整数不带 `.0`，布尔为 true/false。</summary>
    public static string Display(this JsonNode? node, string key)
    {
        if (node is not JsonObject obj || obj[key] is not JsonValue value) return "";
        switch (value.GetValueKind())
        {
            case JsonValueKind.String: return value.GetValue<string>();
            case JsonValueKind.Number:
                var number = value.GetValue<double>();
                return number == Math.Round(number) && Math.Abs(number) < 1e15 ? ((long)number).ToString(CultureInfo.InvariantCulture) : number.ToString("R", CultureInfo.InvariantCulture);
            case JsonValueKind.True: return "true";
            case JsonValueKind.False: return "false";
            default: return "";
        }
    }

    /// <summary>`json.number`（`numberValue`）。</summary>
    public static double? Number(this JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.Number ? value.GetValue<double>() : null;
    public static double? Number(this JsonNode? node, string key) => (node as JsonObject)?[key].Number();

    /// <summary>`json.integer`。</summary>
    public static int Integer(this JsonNode? node, string key) => (int)(Number(node, key) ?? 0);

    /// <summary>`json.bool`：只有 true 才是 true。</summary>
    public static bool Bool(this JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.True;
    public static bool Bool(this JsonNode? node, string key) => (node as JsonObject)?[key].Bool() ?? false;

    /// <summary>`json.items`：不是数组时为空。</summary>
    public static List<JsonNode> Items(this JsonNode? node) => node is JsonArray array ? array.OfType<JsonNode>().ToList() : [];
    public static List<JsonNode> Items(this JsonNode? node, string key) => (node as JsonObject)?[key].Items() ?? [];

    public static JsonNode? Get(this JsonNode? node, string key) => (node as JsonObject)?[key];

    public static string? NonEmpty(this string value) => value.Length == 0 ? null : value;

    /// <summary>ISO 8601（带或不带小数秒）。</summary>
    public static DateTimeOffset? Date(string value) =>
        value.Length > 0 && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var date) ? date : null;
}
