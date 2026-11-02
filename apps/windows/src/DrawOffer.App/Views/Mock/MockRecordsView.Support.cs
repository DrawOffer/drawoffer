using System.ComponentModel;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

// UI-only adapter; grouping, outcome and map rules come from the shared Core port.
internal static class MockReportData
{
    internal sealed record Row(MockMap.Round Round, JsonNode? Evaluation, int No, MockReview.Question? Question)
    {
        public JsonNode Main => Round.Main;
        public List<JsonNode> Turns => Round.Turns;
        public string Id => Main.Display("id");
        public string Topic => Round.Topic;
        public double Level => Question?.Level ?? (Evaluation.Bool("skipped") ? 0 : Math.Clamp(Evaluation.Number("achieved_depth") ?? 0, 0, 5));
        public double Probed => Math.Max(Round.To, Evaluation.Number("probed_depth") ?? 0);
        public string Outcome(double target) => Question?.Outcome switch { MockReview.Outcome.Reached => "reached", MockReview.Outcome.OneShort => "one_short", MockReview.Outcome.Missed => "missed", _ => "unrecorded" };
    }
    public static List<Row> Rows(JsonNode detail, bool includeIntro = false)
    {
        var report = detail.Get("report"); var rows = MockReview.Rows(detail, report);
        var view = MockReview.ViewOf(detail, report, rows, "", "");
        if (!includeIntro) return rows.Select((r, i) => new Row(r.Round, r.Evaluation, r.No, view.Questions[i])).ToList();
        return MockMap.Rounds(detail).Select((round, i) => new Row(round, rows.FirstOrDefault(r => r.Round.Main.Display("id") == round.Main.Display("id"))?.Evaluation, i + 1, view.Questions.FirstOrDefault(q => q.Id == round.Main.Display("id")))).ToList();
    }
    public static double Target(JsonNode detail) => detail.Text("difficulty") switch { "junior" => 2, "senior" => 4, _ => 3 };
    public static string Level(double level) => new[] { "了解", "熟悉", "掌握", "精通", "专家" }[Math.Clamp((int)Math.Round(level) - 1, 0, 4)];
    public static string Difficulty(JsonNode item) => item.Text("difficulty") switch { "junior" => "初级", "senior" => "高级", _ => "中级" };
    public static string Type(JsonNode item) => MockMap.TypeName(item);
    public static string When(JsonNode item) => item.Text("finished_at").NonEmpty() ?? item.Text("started_at").NonEmpty() ?? item.Text("created_at");
    public static string Date(string value) => Json.Date(value)?.ToBeijing().ToString("MM·dd") ?? "—";
    public static string Job(JsonNode item) => item.Display("job_application_id").Length == 0 ? "不挑岗位" : string.Join(" · ", new[] { item.Text("company_name").NonEmpty() ?? "未命名公司", item.Text("job_title").NonEmpty() ?? item.Text("target_role") }.Where(s => s.Length > 0));
    public static string Settings(JsonNode item) => $"{Type(item)} · {Difficulty(item)} · {(item.Text("answer_mode") == "voice" ? "语音" : "文字")} · {item.Integer("question_count")} 题";
    public static string Verdict(string value) => MockMap.VerdictName.GetValueOrDefault(value, value);
    public static Color Tone(string value) => value is "reached" or "likely_pass" or "meets" ? Blue : value is "one_short" or "missed" or "at_risk" or "below" or "likely_fail" or "promising" or "borderline" ? Orange : Fnt;
    public static string Outcome(string value) => value switch { "reached" => "答到位", "one_short" => "差一点", "missed" => "没答上", _ => "没记下" };
    public static string Error(Exception error) => error is ApiException api ? api.Code switch
    {
        "MOCK_INTERVIEW_NOT_FOUND" => "这场模拟面试不存在或已删除。", "MOCK_INTERVIEW_IN_PROGRESS" => "已有进行中的面试，请返回首页继续。",
        "MOCK_INTERVIEW_STATE_INVALID" => "状态已变化，请刷新后再操作。", "MOCK_INTERVIEW_REPORT_OUTDATED" => "这是旧版报告，不能重新评估。",
        "MOCK_INTERVIEW_RE_EVALUATE_LIMIT" => "这道题的重新评估次数已用完。", "MOCK_INTERVIEW_TRANSCRIPT_CHANGE_TOO_LARGE" => "修改幅度超过允许范围，请只改识别错误。",
        "UNAUTHORIZED" => "登录已失效，请重新登录。", _ => $"操作未完成（{api.Code}）。请刷新确认状态。"
    } : "连接失败，请刷新确认状态后再试。";
    public static V3Button LinkButton(string text, Action action) => new(text, action, V3Button.Kind.Text);
    public static TextBlock Paragraph(string text, double size = 13, Color? color = null) { var t = Sans(text, size, color ?? Sub).Wrap().LineHeight(size + 9); t.IsTextSelectionEnabled = true; return t; }
    public static FrameworkElement Tap(UIElement child, Action action, string name)
    {
        var b = new Button { Content = child, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch, Background = Brush(Clear), BorderThickness = new Thickness(0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, name); b.Click += (_, _) => action(); return b;
    }
    public static void Confirm(XamlRoot root, string title, string text, Action confirm) => V3Overlay.Show(root, close => V3Dialog.Make(VStack(12, V3DialogHead.Make(title), Paragraph(text)), [new V3Button("取消", close), new V3Button("确认删除", () => { close(); confirm(); }, V3Button.Kind.Danger)], close));
}

internal sealed class MockViewLifetime : IDisposable
{
    readonly UserControl _view; readonly Action _clear; readonly string? _owner;
    readonly CancellationTokenSource _cancel = new();
    bool _disposed;
    public MockViewLifetime(UserControl view, Action clear)
    {
        (_view, _clear, _owner) = (view, clear, App.Session.User?.Id);
        App.Session.PropertyChanged += Changed;
        view.Unloaded += Unloaded;
    }
    public bool Alive => !_disposed && _owner == App.Session.User?.Id;
    public CancellationToken Token => _cancel.Token;
    void Changed(object? sender, PropertyChangedEventArgs e) { if (_owner != App.Session.User?.Id) { Dispose(); _clear(); } }
    void Unloaded(object sender, RoutedEventArgs e) => Dispose();
    public async Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null, Dictionary<string,string>? query = null)
    {
        var result = await App.Session.Api.CareerRequestAsync(path, method, query, body, Token);
        if (!Alive) throw new OperationCanceledException();
        return result;
    }
    public void Dispose() { if (_disposed) return; _disposed = true; _cancel.Cancel(); App.Session.PropertyChanged -= Changed; _view.Unloaded -= Unloaded; }
}
