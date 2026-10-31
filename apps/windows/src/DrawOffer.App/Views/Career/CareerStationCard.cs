using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using Shapes = Microsoft.UI.Xaml.Shapes;

namespace DrawOffer.App.Views.Career;

/// <summary>站点详情里的动作，对应 Web `StationCard` 的 `DeckAction`（Mac `CareerDeckAction`）；由 `CareerApplicationDetailView` 接到现有弹窗。</summary>
public abstract record CareerDeckAction
{
    public sealed record RecordApplied : CareerDeckAction;
    public sealed record Advance : CareerDeckAction;
    public sealed record Schedule : CareerDeckAction;
    public sealed record Reschedule : CareerDeckAction;
    public sealed record RecordOffer : CareerDeckAction;
    public sealed record EditOffer : CareerDeckAction;
    public sealed record HandleOffer : CareerDeckAction;
    public sealed record EditJob : CareerDeckAction;
    public sealed record EditDelivery : CareerDeckAction;
    public sealed record Reopen : CareerDeckAction;
    public sealed record Reject : CareerDeckAction;
    public sealed record Materials(string SessionId) : CareerDeckAction;
    public sealed record AllMaterials : CareerDeckAction;
    public sealed record Review(JsonNode? Session) : CareerDeckAction;
    public sealed record GenerateReview(JsonNode Session) : CareerDeckAction;
    public sealed record PrepToggle(JsonNode Session, int Index) : CareerDeckAction;
    public sealed record PrepGenerate(JsonNode Session) : CareerDeckAction;
    public sealed record PrepOpen(JsonNode Session) : CareerDeckAction;
    public sealed record Copy(string Text) : CareerDeckAction;
    public sealed record UploadOffer : CareerDeckAction;
}

/// <summary>
/// Web `features/interviews/progress/StationCard.tsx`（Mac `CareerStationCard`）：上半是日历页、标题、说明和右下的操作，下半是三张缩略图。
/// 内容按站点种类与「做之前 / 做之后」分开，文案与 Web 一致。
/// </summary>
public sealed partial class CareerStationCard : UserControl
{
    readonly JsonNode _application;
    readonly CareerDeck _deck;
    readonly CareerStation _station;
    readonly CareerStation? _previous;
    readonly IReadOnlyDictionary<string, JsonNode> _details;
    readonly bool _viewing;
    readonly DateTimeOffset _now;
    readonly bool _busy;
    readonly bool _prepBusy;
    readonly int _materialsCount;
    readonly Action<CareerDeckAction> _act;

    sealed record Hero(DateTimeOffset Day, string Title, string? Sub = null, string? Note = null, string? Tone = null, JsonNode? Place = null);
    sealed record Act(string Label, CareerDeckAction Run, PDButton.Kind Kind = PDButton.Kind.Normal, bool Disabled = false);

    public CareerStationCard(JsonNode application, CareerDeck deck, CareerStation station, CareerStation? previous, IReadOnlyDictionary<string, JsonNode> details,
        bool viewing, DateTimeOffset now, bool busy, bool prepBusy, int materialsCount, Action<CareerDeckAction> act)
    {
        _application = application;
        _deck = deck;
        _station = station;
        _previous = previous;
        _details = details;
        _viewing = viewing;
        _now = now;
        _busy = busy;
        _prepBusy = prepBusy;
        _materialsCount = materialsCount;
        _act = act;
        Content = Body();
    }

    UIElement Body()
    {
        var content = Build();
        var titleRow = HStack(12, Sans($"第 {_station.Index} 站 · {content.Title}", 14, PD.Mute));
        if (content.Status.Length > 0)
        {
            var color = content.StatusTone == "red" ? PD.Red : content.StatusTone == "gray" ? Hex(0x6F6F69) : PD.BlueText;
            var dot = new Shapes.Ellipse { Width = 6, Height = 6, Fill = Brush(content.StatusTone == "red" ? PD.Red : content.StatusTone == "gray" ? PD.Mute : PD.Blue) };
            titleRow.Children.Add(HStack(5, dot, Sans(content.Status, 12.5, color, Medium)));
        }
        titleRow.Height = 20;
        var right = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        right.Children.Add(titleRow);
        var title = Sans(content.Hero.Title, 34, PD.Ink, Medium).Wrap();
        title.CharacterSpacing = -10; // kerning(-0.34)：-0.34 / 34 = -0.01em
        title.MinHeight = 44;
        title.Margin = new Thickness(0, 8, 0, 0);
        right.Children.Add(title);
        if (content.Hero.Sub is { Length: > 0 } sub) right.Children.Add(Sans(sub, 15, PD.Body).Wrap().Also(t => { t.MinHeight = 22; t.Margin = new Thickness(0, 10, 0, 0); }));
        if (content.Hero.Note is { Length: > 0 } note) right.Children.Add(Sans(note, 14, PD.Mute).Wrap().Also(t => { t.MinHeight = 21; t.Margin = new Thickness(0, 4, 0, 0); }));
        if (content.Hero.Place is { } session) right.Children.Add(Place(session));
        var actions = HStack(10, content.Actions.Select(a => (UIElement)new PDButton(a.Label, () => _act(a.Run), a.Kind, !a.Disabled)).ToArray());
        actions.HorizontalAlignment = HorizontalAlignment.Right;
        actions.Margin = new Thickness(0, 26, 0, 0);
        right.Children.Add(actions);
        var hero = Columns(46, (Px(150), CareerCalendarPage.Make(content.Hero.Day, content.Hero.Tone)), (Star(), right));
        var stack = VStack(0, hero, CareerThumbShelf.Make(content.ShelfTitle, content.Shelf, () => _act(new CareerDeckAction.AllMaterials())));
        AutomationProperties.SetName(stack, $"第 {_station.Index} 站：{_station.Title}");
        return stack;
    }

    UIElement Place(JsonNode session)
    {
        var onsite = session.Text("mode") == "onsite" && session.Text("location").Length > 0;
        var text = onsite ? session.Text("location") : session.Text("meeting_url").Replace("https://", "").Replace("http://", "");
        var link = onsite ? "https://uri.amap.com/search?keyword=" + Uri.EscapeDataString(session.Text("location")) : session.Text("meeting_url");
        var row = HStack(8, Icon(onsite ? "mappin.and.ellipse" : "link", 13, PD.Mute), Sans(text, 14, PD.Body),
            Sans("复制", 14, PD.Ink).OnTap(() => _act(new CareerDeckAction.Copy(onsite ? session.Text("location") : session.Text("meeting_url"))), "复制"));
        if (Uri.TryCreate(link, UriKind.Absolute, out var url) && url.Scheme is "http" or "https")
            row.Children.Add(Sans(onsite ? "地图 ↗" : "打开 ↗", 13, PD.Ink, Medium).OnTap(() => _ = Windows.System.Launcher.LaunchUriAsync(url), onsite ? "地图 ↗" : "打开 ↗"));
        row.Height = 20;
        row.Margin = new Thickness(0, 10, 0, 0);
        return row;
    }

    // MARK: 内容

    sealed record CardContent(string Title, Hero Hero, string ShelfTitle, IReadOnlyList<CareerThumb> Shelf, IReadOnlyList<Act> Actions, string Status = "", string? StatusTone = null);

    static string Md(DateTimeOffset? date) => CareerDeckFormat.MonthDay(date);
    static string Clock(DateTimeOffset date) => CareerDeckFormat.Clock(date);
    static string DayLabel(DateTimeOffset date) => $"{Md(date)} {CareerDeckFormat.Weekday(date)}";
    static string? Waited(int days) => days > 0 ? $"已等 {days} 天" : null;
    string RelativeDay(DateTimeOffset date) => CareerFormat.Days(_now, date) switch
    {
        0 => "今天",
        1 => "明天",
        2 => "后天",
        -1 => "昨天",
        _ => DayLabel(date),
    };
    static string EndClock(DateTimeOffset date) { var text = Clock(date); return text == "00:00" ? "24:00" : text; }
    static DateTimeOffset? Date(JsonNode? value, string field) => value is null ? null : CareerApplication.Date(value.Text(field));
    static int Minutes(JsonNode session)
    {
        if (Date(session, "start_at") is not { } s || Date(session, "end_at") is not { } e) return 1;
        return Math.Max(1, (int)Math.Round((e - s).TotalSeconds / 60, MidpointRounding.AwayFromZero));
    }
    JsonNode? Detail(JsonNode? session) => session is not null && _details.TryGetValue(session.Text("id"), out var value) ? value : null;
    static string? DotDate(string raw)
    {
        if (CareerFormat.OfferDate(raw) is not { } value) return null;
        var parts = PD.Local(value);
        return $"{parts.Year}.{CareerDeckFormat.Two(parts.Month)}.{CareerDeckFormat.Two(parts.Day)}";
    }
    static string? Money(string raw)
    {
        if (raw.Length == 0) return null;
        if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var amount)) return raw;
        return amount >= 1000 && amount % 1000 == 0 ? $"{(long)(amount / 1000)}K" : ((long)amount).ToString(CultureInfo.InvariantCulture);
    }

    List<string> Questions(JsonNode session)
    {
        var markdown = Detail(session).Get("session").Text("questions_markdown").NonEmpty() ?? session.Text("questions_markdown");
        return InterviewRecord.Parse(markdown).Select(x => x.Question.Trim().NonEmpty() ?? "（没记下问题）").ToList();
    }

    static string? ReviewHeadline(JsonNode session)
    {
        var report = session.Get("review_report");
        if (report.Number("schema_version") == 2) return report.Text("headline").NonEmpty() ?? report.Text("summary").NonEmpty();
        return report.Text("summary").Trim().NonEmpty() ?? session.Text("review_summary").Trim().NonEmpty();
    }

    static List<string> ReviewGaps(JsonNode session)
    {
        var report = session.Get("review_report");
        List<string> Improvements() => report.Items("questions").Select(x => x.Text("improvement")).Where(x => x.Length > 0).ToList();
        if (report.Number("schema_version") == 2)
        {
            var items = report.Items("improvements").Select(x => x.Text("title")).Where(x => x.Length > 0).ToList();
            return (items.Count == 0 ? Improvements() : items).Take(3).ToList();
        }
        return Improvements().Take(3).ToList();
    }

    List<string> JobSkills()
    {
        var snapshot = _application.Get("job_snapshot");
        var skills = snapshot.Items("skills").Select(x => x.String()?.Trim(' ', '\t').NonEmpty()).OfType<string>().ToList();
        if (skills.Count > 0) return skills.Take(3).ToList();
        var description = snapshot.Text("description");
        return description.Split(['\n', '；', ';', '。'])
            .Select(x => x.Trim(" \t0123456789.、-*·".ToCharArray()))
            .Where(x => x.Length > 0).Take(3).ToList();
    }
}
