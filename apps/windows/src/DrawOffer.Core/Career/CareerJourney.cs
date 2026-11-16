using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DrawOffer.Core.Models;

/// <summary>
/// 投递详情（Windows 稿 07 页 04–09 分区，Mac `CareerJourney.swift`，Web `features/interviews/progress/journey.tsx`）的文案与状态：
/// 上半讲“这一步”——眉题（公司 · 岗位 + 蓝色阶段）、结论标题、一句说明、一个随状态变的黑按钮 + 白色「有新进展」；
/// 右侧随状态换内容；底部是全程时间线。这里只算文案，画法在 App 的 `CareerJourneyViews`。
/// </summary>
public enum CareerJourneyAction
{
    RecordApplied, OpenSource, Advance, Schedule, Reschedule, Enter, Mock,
    GenerateReview, OpenReview, OpenRecord, OpenWritten, RecordOffer, Decide, EditOffer, Reopen, BackToNow,
}

public sealed record CareerJourneyButton(CareerJourneyAction Action, string Label);

/// <summary>右侧随状态放的那一样东西（04 分区「说明 · 右侧随状态」）。</summary>
public enum CareerJourneySide { Resume, Prep, RecordEntry, Questions, Review, Written, Offer, Oc, Left, None }

/// <param name="Editable">末尾带「· 修改安排」。</param>
public sealed record CareerJourneyPlace(string Text, string Copy, Uri? Url, bool Editable);

public sealed record CareerJourneyStep(string Stage, string Title, string? Desc, CareerJourneyPlace? Place, CareerJourneyButton? Primary, CareerJourneyButton? Secondary, CareerJourneySide Side);

public static class CareerJourney
{
    // 小工具

    public static string? RelativeDay(DateTimeOffset value, DateTimeOffset now, TimeZoneInfo? zone = null) =>
        CareerFormat.Days(now, value, zone) switch { 0 => "今天", 1 => "明天", 2 => "后天", -1 => "昨天", _ => null };

    static string Md(DateTimeOffset? date) => CareerDeckFormat.MonthDay(date);
    static string EndClock(DateTimeOffset date) { var text = CareerDeckFormat.Clock(date); return text == "00:00" ? "24:00" : text; }

    static string ModeLabel(JsonNode session) => session.Text("mode") switch { "video" => "视频面试", "onsite" => "现场面试", "phone" => "电话面试", _ => "其他方式" };

    static JsonNode? Live(JsonNode? session) => session is null || session.Text("status") == "cancelled" ? null : session;

    static DateTimeOffset? SessionDay(JsonNode session) =>
        CareerApplication.Date(session.Text(session.Text("schedule_kind") == "open_window" ? "end_at" : "start_at"));

    /// <summary>节点上的日子：有场次用场次时间，没有用进入这一阶段的时间。</summary>
    public static DateTimeOffset StationDay(CareerStation station) => (Live(station.Session) is { } s ? SessionDay(s) : null) ?? station.Start;

    /// <summary>Offer 日期是日历日（`YYYY-MM-DD`），也接受完整时间。</summary>
    public static DateTimeOffset? OfferDate(string raw) => CareerFormat.OfferDate(raw) ?? CareerApplication.Date(raw);

    static string CnCount(int value) => value is >= 1 and <= 9 ? "一二三四五六七八九"[value - 1].ToString() : value.ToString();

    static int InterviewCount(CareerDeck deck) => deck.Stations.Count(x => x.Kind == CareerStationKind.Interview && Live(x.Session) is not null);

    public static Uri? SourceUrl(JsonNode app)
    {
        var value = app.Get("job_snapshot").Text("source_url");
        return (value.StartsWith("http://") || value.StartsWith("https://")) && Uri.TryCreate(value, UriKind.Absolute, out var uri) ? uri : null;
    }

    static string Clip(string text, int count) => text.Length > count ? text[..count] + "…" : text;

    // 复盘结论（和报告页同一套判定，含用户改过的层）

    sealed record GraphQuestion(string Key, string Kind, string Title, string Topic, string Outcome, string Answer);

    static string CategoryLabel(string value) => value switch { "technical" => "技术题", "project" => "项目题", "behavioral" => "行为题", "hr" => "HR 题", _ => "" };

    /// <summary>Web `review/model.ts` 的 `outcomeOf`。</summary>
    static string Outcome(JsonNode question, int? userDepth)
    {
        var kind = question.Text("kind").NonEmpty() ?? "main";
        if (kind == "reverse") return "not_judged";
        if (userDepth is null && question.Text("outcome").NonEmpty() is { } value) return value;
        if (question.Text("answer_status") == "missing") return "unrecorded";
        if (question.Text("answer_status") == "declined" && userDepth is null) return "missed";
        var layered = question.Get("depth_scored") is JsonValue flag && flag.TryGetValue<bool>(out var scored) ? scored : !new[] { "hr", "behavioral" }.Contains(question.Text("category"));
        if (!layered && userDepth is null)
        {
            var verdicts = question.Items("signals").Select(x => x.Text("verdict")).Where(x => x != "not_probed").ToList();
            if (verdicts.Count == 0) return "unrecorded";
            var share = verdicts.Sum(x => x == "hit" ? 1.0 : x == "partial" ? 0.5 : 0) / verdicts.Count;
            return share >= 0.67 ? "reached" : share >= 0.34 ? "one_short" : "missed";
        }
        var depth = userDepth ?? (question.Number("achieved_depth") is { } achieved ? (int)achieved : null);
        if (depth is null) return "unrecorded";
        var target = (int)(question.Number("target_depth") ?? question.Number("expected_depth") ?? 3);
        var gap = target - depth.Value;
        return gap <= 0 ? "reached" : gap == 1 ? "one_short" : "missed";
    }

    static List<GraphQuestion>? Graph(JsonNode session)
    {
        var report = session.Get("review_report");
        if (!CareerReview.IsV2(report)) return null;
        var notes = new Dictionary<string, int>();
        foreach (var note in session.Items("review_question_notes"))
            if (note.Number("user_depth") is { } depth) notes[note.Text("question_key")] = (int)depth;
        return report.Items("questions").Select(source =>
        {
            var kind = source.Text("kind").NonEmpty() ?? "main";
            var clean = Regex.Replace(source.Text("question").Trim(), "[？?。.！!]+$", "");
            var shortText = Clip(clean, 10);
            return new GraphQuestion(source.Text("key"), kind,
                kind == "reverse" ? "反问" : source.Text("title").Trim().NonEmpty() ?? shortText,
                kind == "reverse" ? "反问" : source.Text("topic").Trim().NonEmpty() ?? CategoryLabel(source.Text("category")),
                Outcome(source, notes.TryGetValue(source.Text("key"), out var d) ? d : null),
                source.Text("answer"));
        }).ToList();
    }

    public sealed record WeakPoint(string Id, string Title, string Detail, string? Quote);

    /// <summary>复盘里没答到位的几处：只算没答上和差一层。</summary>
    public static List<WeakPoint> WeakPoints(JsonNode? session, string? stageShort = null)
    {
        if (session is null || Graph(session) is not { } questions) return [];
        return questions.Where(x => x.Kind != "reverse" && x.Outcome is "missed" or "one_short").Select(item =>
        {
            var missed = item.Outcome == "missed";
            var answer = Regex.Replace(item.Answer, @"\s+", " ").Trim();
            var what = missed ? "没答上" : "差一层";
            string? topic = item.Topic.Length == 0 ? null : item.Topic[0] < 128 ? $"属于 {item.Topic}" : $"属于{item.Topic}";
            var clip = Clip(answer, 24);
            return new WeakPoint(item.Key, Clip(item.Title, 16),
                string.Join(" · ", new[] { topic, stageShort is null ? what : stageShort + what }.OfType<string>()),
                answer.Length == 0 ? null : missed ? $"你停在“{clip}”" : $"你只说了“{clip}”");
        }).ToList();
    }

    public static int MissedCount(JsonNode? session) => WeakPoints(session).Count;

    /// <summary>Web `ReviewBand.reviewHeadline(...).detail`：差一层 / 答到位 / 没记下各几题。</summary>
    public static string ReviewDetail(JsonNode session)
    {
        if (Graph(session) is not { } questions) return "点开看每道题的分析";
        var marks = questions.Select(x => x.Outcome switch { "reached" => "good", "one_short" => "shallow", "missed" => "missed", _ => "unrecorded" }).ToList();
        int Count(string kind) => marks.Count(x => x == kind);
        var parts = string.Join(" · ", new[]
        {
            Count("shallow") > 0 && marks.Contains("missed") ? $"差一层 {Count("shallow")}" : null,
            Count("good") > 0 ? $"答到位 {Count("good")}" : null,
            Count("unrecorded") > 0 ? $"没记下 {Count("unrecorded")}" : null,
        }.OfType<string>());
        return parts.Length == 0 ? session.Get("review_report").Text("headline") : parts;
    }

    // 面试记录状态（Web `StationCard.recordState`）

    public abstract record RecordState
    {
        public sealed record None : RecordState;
        public sealed record Ready(int Questions, string Source) : RecordState;
        public sealed record Transcribing(string File, int? Minutes) : RecordState;
        public sealed record Failed(string File, string DatasetId) : RecordState;
    }

    public static string Markdown(JsonNode session, JsonNode? detail) =>
        detail.Get("session").Text("questions_markdown").NonEmpty() ?? session.Text("questions_markdown");

    public static RecordState Record(JsonNode session, JsonNode? detail)
    {
        var questions = InterviewRecord.Parse(Markdown(session, detail));
        var transcriptions = detail.Get("session")?.Get("transcriptions") is JsonArray fromDetail ? fromDetail.Items() : session.Items("transcriptions");
        var assets = detail.Items("assets");
        string Name(string id) => assets.FirstOrDefault(x => x.Text("id") == id)?.Text("original_file_name").NonEmpty() ?? "录音";
        if (questions.Count > 0)
            return new RecordState.Ready(questions.Count, session.Text("transcript_source") == "transcription" ? "录音转写" : "文字整理");
        if (transcriptions.FirstOrDefault(x => x.Text("status") is "queued" or "running") is { } active)
        {
            var id = active.Text("dataset_id");
            var duration = assets.FirstOrDefault(x => x.Text("id") == id).Number("duration_ms");
            return new RecordState.Transcribing(Name(id), duration is { } ms ? Math.Max(1, (int)Math.Round(ms / 600_000, MidpointRounding.AwayFromZero)) : null);
        }
        if (transcriptions.FirstOrDefault(x => x.Text("status") == "failed") is { } failed)
            return new RecordState.Failed(Name(failed.Text("dataset_id")), failed.Text("dataset_id"));
        return new RecordState.None();
    }

    // Offer

    static string? Money(string raw)
    {
        if (raw.Length == 0) return null;
        if (!double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var amount)) return raw;
        return amount >= 1000 && amount % 1000 == 0 ? $"{(int)(amount / 1000)}K" : amount == Math.Round(amount) ? $"{(long)amount}" : amount.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    static int? OfferMonths(JsonNode app)
    {
        var match = Regex.Match(app.Text("offer_benefits_description"), @"(\d{2})\s*薪");
        return match.Success ? int.Parse(match.Groups[1].Value) : null;
    }

    /// <summary>「22K × 15」。</summary>
    public static string? OfferSalary(JsonNode app) =>
        Money(app.Display("offer_salary")) is { } salary ? salary + (OfferMonths(app) is { } months ? $" × {months}" : "") : null;

    /// <summary>「年包约 33 万」/「年薪」。</summary>
    public static string? OfferYearly(JsonNode app)
    {
        var raw = app.Display("offer_salary");
        if (raw.Length > 0 && app.Text("offer_salary_period") != "year" && OfferMonths(app) is { } months
            && double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var amount))
        {
            var value = Math.Round(amount * months / 1000) / 10;
            return $"年包约 {(value == Math.Round(value) ? ((long)value).ToString() : value.ToString(System.Globalization.CultureInfo.InvariantCulture))} 万";
        }
        return app.Text("offer_salary_period") == "year" ? "年薪" : null;
    }

    public static string? DotDate(string raw)
    {
        if (OfferDate(raw) is not { } date) return null;
        var local = SwiftCalendar.Local(date, Beijing.Zone);
        return $"{local.Year}.{CareerDeckFormat.Two(local.Month)}.{CareerDeckFormat.Two(local.Day)}";
    }

    // 这一步

    public static CareerJourneyStep Step(JsonNode app, CareerDeck deck, CareerStation station, bool viewing, DateTimeOffset now,
        JsonNode? detail, CareerStation? previous, string? reviewCost)
    {
        var advance = new CareerJourneyButton(CareerJourneyAction.Advance, "有新进展");
        var current = deck.Current ?? deck.Stations[^1];
        var backToNow = new CareerJourneyButton(CareerJourneyAction.BackToNow, "回到" + (deck.Pending ? "待投递" : current.Short));
        var session = Live(station.Session);
        CareerJourneyPlace? PlaceOf(bool editable)
        {
            if (session is null) return null;
            var location = session.Text("location");
            var meeting = session.Text("meeting_url");
            if (session.Text("mode") == "onsite" && location.Length > 0)
                return new CareerJourneyPlace(location, location, new Uri("https://uri.amap.com/search?keyword=" + Uri.EscapeDataString(location)), editable);
            if (meeting.Length > 0)
                return new CareerJourneyPlace(Regex.Replace(meeting, "^https?://", ""), meeting, Uri.TryCreate(meeting, UriKind.Absolute, out var url) ? url : null, editable);
            return null;
        }
        static CareerJourneyStep Make(string stage, string title, string? desc, CareerJourneySide side, CareerJourneyPlace? place = null, CareerJourneyButton? primary = null, CareerJourneyButton? secondary = null) =>
            new(stage, title, desc, place, primary, secondary, side);
        var anyReview = deck.Stations.Reverse().FirstOrDefault(x => CareerDeck.HasReview(x.Session))?.Session;

        // 09 分区：已结束，结论直接说结果
        if (deck.Ended is { } ended && !viewing)
        {
            var last = deck.Stations[^1];
            var interviews = InterviewCount(deck);
            var walked = interviews > 0 ? $"走了 {deck.Days} 天、{CnCount(interviews)}场面试" : $"走了 {deck.Days} 天";
            var review = anyReview is not null ? new CareerJourneyButton(CareerJourneyAction.OpenReview, "查看复盘") : null;
            switch (ended.Kind)
            {
                case CareerDeckEndedKind.Withdrew:
                    return Make("已结束", $"{last.Short}之后，不继续了。", $"{Md(ended.At)} 你结束了这条投递。想回来随时可以恢复，之前的记录和复盘都在。", CareerJourneySide.Left,
                        primary: new CareerJourneyButton(CareerJourneyAction.Reopen, "恢复投递"), secondary: review);
                case CareerDeckEndedKind.Accepted:
                    var start = OfferDate(app.Text("offer_start_on"));
                    var local = start is { } s ? SwiftCalendar.Local(s, Beijing.Zone) : (DateTime?)null;
                    return Make("已接受", local is { } l ? $"Offer 接受了，{l.Year} 年 {l.Month} 月入职。" : "Offer 接受了。",
                        $"{Md(ended.At)} 接受的。{walked}，记录和复盘都留着。", CareerJourneySide.Offer, primary: review);
                case CareerDeckEndedKind.Declined:
                    return Make("已结束", "婉拒了这个 Offer。", $"{Md(ended.At)} 婉拒的。{walked}，记录和复盘都留着。", CareerJourneySide.Offer, primary: review);
                case CareerDeckEndedKind.Rejected:
                    return Make("已结束", $"{last.Short}没通过。", anyReview is not null ? $"{walked}。没答上的地方都留下来了，下次会先提醒你。" : $"{walked}。记录都留着，之后的投递还能参考。",
                        CareerJourneySide.Left, primary: review);
                default:
                    return Make("已结束", "这条投递结束了。", $"{walked}。记录都留着。", CareerJourneySide.Left, primary: review);
            }
        }

        // 04 分区：投递前与筛选
        if (station.Kind == CareerStationKind.Apply && deck.Pending)
        {
            var created = CareerApplication.Date(app.Text("created_at")) ?? now;
            var days = CareerDeckFormat.DayCount(created, now);
            return Make("待投递", "还没投，选一份简历投出去。", (days > 0 ? $"{Md(created)} 导入，已经放了 {days} 天。" : "今天导入的。") + "投完回来记一笔。", CareerJourneySide.Resume,
                primary: new CareerJourneyButton(CareerJourneyAction.RecordApplied, "记录投递"),
                secondary: SourceUrl(app) is not null ? new CareerJourneyButton(CareerJourneyAction.OpenSource, "去官网投递 ↗") : null);
        }
        if (station.Kind == CareerStationKind.Apply)
        {
            var channel = CareerDeck.Source(app);
            var resume = app.Text("resume_title_snapshot");
            return Make($"投递 · {Md(station.Start)}", channel is not null ? $"{Md(station.Start)} 在{channel}投出去。" : $"{Md(station.Start)} 投出去。",
                resume.Length == 0 ? null : $"投的是「{resume}」。", CareerJourneySide.Resume, secondary: backToNow);
        }
        if (station.Kind == CareerStationKind.Screening)
        {
            if (station.Current && !viewing)
            {
                var days = CareerDeckFormat.DayCount(station.Start, now);
                var channel = CareerDeck.Source(app);
                return Make("筛选中", days > 0 ? $"投出去 {days} 天了，等简历筛选。" : "今天投出去，等简历筛选。",
                    (channel is not null ? $"{Md(station.Start)} 在{channel}投的。" : "") + "没消息不用急，收到笔试或面试通知时，点「有新进展」记一笔。",
                    CareerJourneySide.Resume, primary: advance);
            }
            var failed = station.Result == "rejected";
            return Make("筛选 · " + (failed ? "没通过" : "已通过"), failed ? "简历筛选没通过。" : "简历筛选通过。",
                station.End is { } end ? $"投出去 {CareerDeckFormat.DayCount(station.Start, end)} 天后出结果。" : null, CareerJourneySide.Resume, secondary: backToNow);
        }

        // 09 分区：OC 与 Offer
        if (station.Kind == CareerStationKind.Oc)
        {
            var at = CareerApplication.Date(app.Text("oc_communicated_at")) ?? station.Start;
            if (station.Current && !viewing)
            {
                var contact = app.Text("oc_contact").NonEmpty() ?? "HR";
                return Make("OC · 口头 Offer", "拿到口头 Offer，等正式的。", $"{contact} {Md(at)}沟通的，正式 Offer 一般一到两周内发。收到后在这里记下。",
                    CareerJourneySide.Oc, primary: new CareerJourneyButton(CareerJourneyAction.RecordOffer, "记录正式 Offer"));
            }
            return Make($"OC · {Md(at)}", "拿到口头 Offer。", $"{Md(at)} 沟通，之后转成了正式 Offer。", CareerJourneySide.Oc, secondary: backToNow);
        }
        if (station.Kind == CareerStationKind.Offer)
        {
            if (app.Text("offer_status") == "none")
                return Make("Offer · 信息待补充", "收到 Offer，先把信息补上。", "薪资、入职和答复截止填进来，做决定时一眼看全。",
                    CareerJourneySide.Offer, primary: new CareerJourneyButton(CareerJourneyAction.EditOffer, "编辑 Offer 信息"));
            var due = OfferDate(app.Text("offer_reply_due_on"));
            int? left = due is { } d ? CareerFormat.Days(now, d) : null;
            var title = left is { } n ? (n > 0 ? $"Offer 还有 {n} 天要答复。" : n == 0 ? "Offer 今天要答复。" : "Offer 已过答复截止。") : "收到 Offer，还没填答复截止。";
            return Make("Offer · 待答复", title, due is { } dd ? $"{Md(dd)} 前答复。接受之后，其他还在进行的投递不会自动结束。" : "答复截止可以在 ⋯ 里的「编辑 Offer 信息」补上。",
                CareerJourneySide.Offer, primary: new CareerJourneyButton(CareerJourneyAction.Decide, "做决定"));
        }

        // 05–08 分区：笔试 / 测评 / 面试
        var written = station.Kind == CareerStationKind.Written;
        var isNow = station.Current && !viewing;

        if (isNow && session is null && deck.StageState == "awaiting_schedule")
        {
            var waited = CareerDeckFormat.DayCount(station.Start, now);
            var passed = previous?.Kind == CareerStationKind.Interview ? previous : null;
            var desc = written ? "笔试通知一般会给一个作答时段。把时段和链接填进来，截止前会出现在面试日程里。"
                : (passed is not null ? $"{passed.Short} {Md(StationDay(passed))} 通过" : $"{Md(station.Start)} 收到通知") + (waited > 0 ? $"，已经等了 {waited} 天。" : "。") + "收到时间后填进来，时间线和面试日程会一起更新。";
            return Make($"{station.Short} · 待安排", written ? $"收到{station.Short}，还没定时间。" : $"{station.Short}，等对方约时间。", desc, CareerJourneySide.Prep,
                primary: new CareerJourneyButton(CareerJourneyAction.Schedule, "安排时间"), secondary: advance);
        }

        if (isNow && session is not null && session.Text("status") == "scheduled" && CareerApplication.Date(session.Text("end_at")) is { } endAt && endAt > now)
        {
            var start = CareerApplication.Date(session.Text("start_at")) ?? endAt;
            var meeting = session.Text("meeting_url").Length > 0;
            if (written || session.Text("schedule_kind") == "open_window")
            {
                var remain = CareerDeckFormat.Remaining(endAt, now, "还剩");
                int? minutes = session.Text("schedule_kind") == "open_window" ? null : Math.Max(1, (int)Math.Round((endAt - start).TotalMinutes, MidpointRounding.AwayFromZero));
                var desc = string.Join("，", new[] { remain is not null ? $"作答窗口{remain}" : null, minutes is { } m ? $"约 {m} 分钟" : null }.OfType<string>()) + "。做之前把右边几处过一遍。";
                return Make($"{station.Short} · 线上", $"{Md(endAt)} {EndClock(endAt)} 前做完{station.Short}。", desc, CareerJourneySide.Prep, PlaceOf(true),
                    primary: meeting ? new CareerJourneyButton(CareerJourneyAction.Enter, $"进入{station.Short}") : advance, secondary: meeting ? advance : null);
            }
            var day = RelativeDay(start, now);
            var today = day == "今天";
            var leftText = CareerDeckFormat.Remaining(start, now);
            var prepLeft = session.Items("prep_items").Count(x => x.Get("done") is not JsonValue v || !v.TryGetValue<bool>(out var done) || !done);
            var prevWeak = previous is not null && previous.Kind == CareerStationKind.Interview && MissedCount(previous.Session) > 0 ? previous : null;
            var description = today
                ? (leftText is not null ? $"{leftText}，" : "") + (meeting ? "会议链接在下面。" : session.Text("location").Length > 0 ? "地点在下面。" : "") + (prepLeft > 0 ? $"准备清单还剩 {prepLeft} 项没勾。" : "")
                : (leftText is not null ? $"{leftText}，" : "") + (meeting ? "会议链接已经存好。" : "") + (prevWeak is not null ? $"面试前练一场，重点放在{prevWeak.Short}没接住的地方。" : "面试前可以先练一场。");
            return Make($"{station.Short} · {ModeLabel(session)}", $"{day ?? $"{Md(start)} {CareerDeckFormat.Weekday(start)}"} {CareerDeckFormat.Clock(start)}，{station.Short}。", description,
                CareerJourneySide.Prep, PlaceOf(true),
                primary: today && meeting ? new CareerJourneyButton(CareerJourneyAction.Enter, "进入会议") : new CareerJourneyButton(CareerJourneyAction.Mock, "模拟这场面试"),
                secondary: advance);
        }

        if (session is not null)
        {
            var record = Record(session, detail);
            var result = station.Result == "rejected" ? "没通过" : "已通过";
            if (written)
            {
                var questions = detail.Get("session")?.Get("written_questions") is JsonArray fromDetail ? fromDetail.Items() : session.Items("written_questions");
                if (isNow)
                    return Make($"{station.Short} · 已做完", $"{station.Short}做完了，等结果。",
                        questions.Count == 0 ? "趁还记得，把题目记下来，之后能逐题标对错。" : $"记了 {questions.Count} 道题，可以逐题标对错。", CareerJourneySide.Written, primary: advance);
                return Make($"{station.Short} · {Md(StationDay(station))} · {result}", station.Result == "rejected" ? $"{station.Short}没通过。" : $"{station.Short}通过了。",
                    questions.Count == 0 ? null : $"记了 {questions.Count} 道题。", CareerJourneySide.Written,
                    primary: questions.Count == 0 ? null : new CareerJourneyButton(CareerJourneyAction.OpenWritten, $"查看{station.Short}题"), secondary: backToNow);
            }
            var reviewed = session.Text("review_status") != "failed" && CareerDeck.HasReview(session);
            var missed = MissedCount(session);
            if (isNow)
            {
                var stage = reviewed ? $"{station.Short} · 已复盘" : $"{station.Short} · 已面完";
                if (reviewed)
                    return Make(stage, missed > 0 ? $"{station.Short}有 {missed} 处没答到位。" : $"{station.Short}每道题都答到了位。", ReviewDetail(session), CareerJourneySide.Review,
                        PlaceOf(false), new CareerJourneyButton(CareerJourneyAction.OpenReview, "查看复盘"), advance);
                if (session.Text("review_status") == "generating")
                    return Make(stage, $"正在复盘{station.Short}。", "一般 1 分钟左右，好了这里会更新，可以先去做别的。", CareerJourneySide.Questions, PlaceOf(false), secondary: advance);
                if (record is RecordState.Ready ready)
                {
                    var failed = session.Text("review_status") == "failed";
                    return Make(stage, $"记下 {ready.Questions} 道题，可以复盘了。", failed ? "上次没生成出来，可以再试一次。" : "复盘会逐题对照你的回答，标出哪里没答到位、该怎么补。",
                        CareerJourneySide.Questions, PlaceOf(false),
                        new CareerJourneyButton(CareerJourneyAction.GenerateReview, string.Join(" · ", new[] { failed ? "再试一次" : "生成复盘", reviewCost }.OfType<string>())), advance);
                }
                return Make(stage, $"{station.Short}面完了，等结果。",
                    record is RecordState.Transcribing ? "录音正在转成文字，好了会按问题拆好。" : "趁还记得，把问了什么记下来。记下来才能复盘，下一轮前也知道该补哪里。",
                    CareerJourneySide.RecordEntry, PlaceOf(false), secondary: advance);
            }
            // 07.08：回看过去的一轮
            int? count = record is RecordState.Ready r ? r.Questions : null;
            var verb = station.Result == "rejected" ? "没通过" : "通过";
            var heading = reviewed
                ? (missed > 0 ? $"{station.Short}{verb}，{missed} 处没答到位。" : $"{station.Short}{verb}，每道题都答到了位。")
                : (station.Result == "rejected" ? $"{station.Short}没通过。" : $"{station.Short}通过了。");
            return Make($"{station.Short} · {Md(StationDay(station))} · {result}", heading,
                reviewed ? ReviewDetail(session) : count is { } c ? $"记了 {c} 道题，还没复盘。" : "这一轮还没有面试记录。",
                reviewed ? CareerJourneySide.Review : count is not null ? CareerJourneySide.Questions : CareerJourneySide.RecordEntry,
                primary: reviewed ? new CareerJourneyButton(CareerJourneyAction.OpenReview, "查看复盘") : count is not null ? new CareerJourneyButton(CareerJourneyAction.OpenRecord, "查看面试记录") : null,
                secondary: backToNow);
        }

        if (isNow)
            return Make(station.Short, $"等{station.Short}的结果。", "这一轮没有记下时间。收到消息后，点「有新进展」记一笔。", CareerJourneySide.Prep, primary: advance);
        var no = station.Result == "rejected";
        return Make($"{station.Short} · " + (no ? "没通过" : "已通过"), no ? $"{station.Short}没通过。" : $"{station.Short}通过了。", "这一轮没有记下时间。", CareerJourneySide.None, secondary: backToNow);
    }

    // 全程时间线（各分区底部）

    public enum NodeKind { Past, Current, Future, Failed }

    /// <param name="Note">「3 处没答到位」，带橙点。</param>
    /// <param name="StationId">可以点开回看的站点。</param>
    public sealed record Node(string Id, string Label, string? Line, string? Note, NodeKind Kind, string? StationId, DateTimeOffset? Day);

    public enum SegmentStyle { Past, Current, Future }

    public sealed record Segment(SegmentStyle Style, int? Days);

    /// <param name="Today">「今天」竖线落在第几段的哪个位置。</param>
    public sealed record Timeline(string Head, IReadOnlyList<Node> Nodes, IReadOnlyList<Segment> Segments, (int Segment, double Ratio)? Today);

    static string? NodeLine(CareerStation station, CareerDeck deck, DateTimeOffset now, bool isLast)
    {
        var day = StationDay(station);
        if (station.Kind == CareerStationKind.Apply) return deck.Pending ? "待投递" : Md(station.Start);
        if (isLast && deck.Ended is { } ended)
        {
            var word = ended.Kind switch
            {
                CareerDeckEndedKind.Rejected => "没通过", CareerDeckEndedKind.Accepted => "已接受", CareerDeckEndedKind.Withdrew => "我不继续了",
                CareerDeckEndedKind.Declined => "已婉拒", _ => "已结束",
            };
            return $"{Md(day)} · {word}";
        }
        if (!station.Current) return station.Result == "rejected" ? $"{Md(day)} · 没通过" : station.Result == "passed" ? $"{Md(day)} · 通过" : Md(day);
        if (station.Kind == CareerStationKind.Screening)
        {
            var waited = CareerDeckFormat.DayCount(station.Start, now);
            return waited > 0 ? $"已等 {waited} 天" : "今天投递";
        }
        if (station.Kind == CareerStationKind.Oc) return $"{Md(day)} · 等正式 Offer";
        if (station.Kind == CareerStationKind.Offer) return $"{Md(day)} · 待答复";
        if (Live(station.Session) is not { } session) return deck.StageState == "awaiting_schedule" ? "待安排" : "等结果";
        if (day > now)
        {
            if (session.Text("schedule_kind") == "open_window") return $"{Md(day)} 前";
            return $"{Md(day)} · {RelativeDay(day, now) ?? CareerDeckFormat.Weekday(day)}";
        }
        return RelativeDay(day, now) == "今天" ? $"{Md(day)} · 今天" : $"{Md(day)} · 等结果";
    }

    static IEnumerable<string> FutureLabels(CareerDeck deck, DateTimeOffset now)
    {
        if (deck.Ended is not null) return [];
        var current = deck.Current ?? deck.Stations[^1];
        switch (current.Kind)
        {
            case CareerStationKind.Apply: return ["筛选", "笔试 / 测评", "面试", "Offer"];
            case CareerStationKind.Screening: return ["笔试 / 测评", "面试", "Offer"];
            case CareerStationKind.Written: return ["面试", "Offer"];
            case CareerStationKind.Interview:
                if (current.Session is not { } session) return ["Offer"];
                var done = session.Text("status") == "completed" || (CareerApplication.Date(session.Text("end_at")) is { } end && end < now);
                return done ? ["下一面", "Offer"] : ["Offer"];
            case CareerStationKind.Oc: return ["Offer"];
            default: return [];
        }
    }

    public static Timeline Build(JsonNode app, CareerDeck deck, DateTimeOffset now)
    {
        var lastIndex = deck.Stations.Count - 1;
        var nodes = deck.Stations.Select((station, index) =>
        {
            var failed = station.Result == "rejected" || (index == lastIndex && deck.Ended?.Kind == CareerDeckEndedKind.Rejected);
            var missed = MissedCount(station.Session);
            var line = NodeLine(station, deck, now, index == lastIndex);
            if (station.Kind == CareerStationKind.Apply && !deck.Pending)
            {
                var channel = CareerDeck.Source(app);
                line = channel is not null && channel.Length <= 4 ? $"{Md(station.Start)} · {channel}" : Md(station.Start);
            }
            return new Node(station.Id, station.Kind == CareerStationKind.Apply && deck.Pending ? "投递" : station.Short, line,
                missed > 0 ? $"{missed} 处没答到位" : null,
                failed ? NodeKind.Failed : station.Current && deck.Ended is null ? NodeKind.Current : NodeKind.Past,
                station.Id, station.Kind == CareerStationKind.Apply && deck.Pending ? null : StationDay(station));
        }).ToList();
        foreach (var label in FutureLabels(deck, now)) nodes.Add(new Node("future-" + label, label, null, null, NodeKind.Future, null, null));
        var head = deck.Ended is not null ? $"共 {deck.Days} 天" : deck.Pending ? $"导入 {deck.Days} 天，还没投递" : $"从投递到现在 · {deck.Days} 天";

        var segments = new List<Segment>();
        for (var index = 0; index < nodes.Count - 1; index++)
        {
            var node = nodes[index];
            var next = nodes[index + 1];
            var screeningNow = next.Kind == NodeKind.Current && deck.Stations.FirstOrDefault(x => x.Id == next.StationId)?.Kind == CareerStationKind.Screening;
            int? days = next.Kind == NodeKind.Future || node.Day is not { } from ? null : (screeningNow ? now : next.Day) is { } to ? (int?)CareerDeckFormat.DayCount(from, to) : null;
            segments.Add(new Segment(next.Kind == NodeKind.Future ? SegmentStyle.Future : next.Kind == NodeKind.Current ? SegmentStyle.Current : SegmentStyle.Past, days is > 0 ? days : null));
        }

        // 「今天」：当前节点在未来时画在它前面那段，已面完在等结果时贴在它后面那段
        (int, double)? today = null;
        var currentIndex = nodes.FindIndex(x => x.Kind == NodeKind.Current);
        if (currentIndex > 0 && deck.Ended is null)
        {
            var node = nodes[currentIndex];
            var before = nodes[currentIndex - 1];
            if (node.Day is { } day && before.Day is { } start && day > now)
            {
                var total = (day - start).TotalSeconds;
                today = (currentIndex - 1, total > 0 ? Math.Min(0.88, Math.Max(0.12, (now - start).TotalSeconds / total)) : 0.5);
            }
            else if (deck.Stations.FirstOrDefault(x => x.Id == node.StationId) is { Session: not null } && currentIndex < nodes.Count - 1 && RelativeDay(node.Day ?? now, now) != "今天")
                today = (currentIndex, 0.16);
        }
        return new Timeline(head, nodes, segments, today);
    }

    // 右侧：面试中问到（07.06）

    /// <param name="Position">这题在完整记录里的位置，用来打开记录。</param>
    public sealed record TopicCard(string Id, string Title, string Meta, string Quote, int Position, bool Many);

    static string PositionsText(IReadOnlyList<int> positions)
    {
        var parts = new List<string>();
        var start = 0;
        while (start < positions.Count)
        {
            var end = start;
            while (end + 1 < positions.Count && positions[end + 1] == positions[end] + 1) end++;
            if (end - start >= 2) parts.Add($"{positions[start]}–{positions[end]}");
            else for (var i = start; i <= end; i++) parts.Add(positions[i].ToString());
            start = end + 1;
        }
        return string.Join("、", parts);
    }

    static readonly Regex Reverse = new("^反问[：:]");
    static readonly Regex Generic = new("自我介绍|介绍一下(你)?自己|求职动机|为什么(选择|想来|投递|离职)|离职原因|职业规划");

    /// <summary>反问不算考点；按考点归组列原话，不下判断；考点还没整理好时先按题列。最多三张。</summary>
    public static List<TopicCard> TopicCards(IReadOnlyList<RecordQuestion> questions, IReadOnlyList<JsonNode>? groups)
    {
        var mains = questions.Select((q, i) => (Offset: i, Element: q)).Where(x => x.Element.Reply is null && !Reverse.IsMatch(x.Element.Question.Trim())).ToList();
        static string Quote(string text) => $"“{text.Trim().NonEmpty() ?? "（没记下问题）"}”";
        var cards = new List<(TopicCard Card, bool Generic)>();
        if (groups is not null)
        {
            foreach (var group in groups)
            {
                var members = group.Items("questions").Select(x => x.Number()).OfType<double>().Select(x => (int)x)
                    .Where(x => x >= 1 && x <= mains.Count).Select(x => mains[x - 1]).ToList();
                if (members.Count == 0) continue;
                var first = members[0];
                var numbers = members.Select(x => x.Offset + 1).ToList();
                var topic = group.Text("topic").NonEmpty();
                var text = first.Element.Question.Trim();
                var many = members.Count > 1;
                cards.Add((new TopicCard((topic ?? "") + $"-{numbers[0]}",
                    topic ?? (text.Length > 16 ? text[..16] + "…" : text.NonEmpty() ?? $"第 {numbers[0]} 题"),
                    many ? $"问了 {members.Count} 题 · 第 {PositionsText(numbers)} 题" : $"第 {numbers[0]} 题",
                    Quote(first.Element.Question), first.Offset, many),
                    Generic.IsMatch($"{topic ?? ""} {first.Element.Question}")));
            }
        }
        else
        {
            foreach (var (position, item) in mains)
                cards.Add((new TopicCard(position.ToString(), $"第 {position + 1} 题",
                    item.FollowUps.Count == 0 ? "没有追问" : $"被追问了 {item.FollowUps.Count} 次", Quote(item.Question), position, false),
                    Generic.IsMatch(item.Question)));
        }
        var ordered = cards.Where(x => x.Card.Many).Concat(cards.Where(x => !x.Card.Many && !x.Generic)).Concat(cards.Where(x => !x.Card.Many && x.Generic));
        return ordered.Take(3).Select(x => x.Card).OrderBy(x => x.Position).ToList();
    }

    /// <summary>送去整理考点的题目（反问除外，最多 60 题）。</summary>
    public static List<string> TopicQuestions(IReadOnlyList<RecordQuestion> questions) =>
        questions.Where(x => x.Reply is null && !Reverse.IsMatch(x.Question.Trim())).Take(60)
            .Select(x => { var t = x.Question.Trim(); return (t.Length > 2000 ? t[..2000] : t).NonEmpty() ?? "（没记下问题）"; }).ToList();
}
