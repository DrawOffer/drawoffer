using System.Text.Json.Nodes;
using System.Globalization;

namespace DrawOffer.Core.Models;

public static class MockSession
{
    public static JsonNode? Current(JsonNode? detail) { var id = detail.Display("current_question_id"); return id.Length == 0 ? null : detail.Items("questions").FirstOrDefault(q => q.Display("id") == id); }
    public static JsonNode? LastAsked(JsonNode? detail) => detail.Items("questions").OrderByDescending(q => q.Number("sequence_no") ?? 0).FirstOrDefault();
    public static MockMap.Round? RoundOf(JsonNode? detail, JsonNode? question) { if (question is null) return null; var root = question.Display("parent_id").NonEmpty() ?? question.Display("id"); return MockMap.Rounds(detail).FirstOrDefault(r => r.Main.Display("id") == root); }
    public static string Mmss(double seconds) { var total = Math.Max(0, (int)seconds); return (total / 60).ToString("00", CultureInfo.InvariantCulture) + ":" + (total % 60).ToString("00", CultureInfo.InvariantCulture); }
    public static bool HasAnswered(JsonNode? detail) => detail.Items("questions").Any(q => q.Text("answer_status") == "answered" && !MockMap.IsIntro(detail, q));
}
