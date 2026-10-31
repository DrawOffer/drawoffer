using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.Core.Models;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerStationCard
{
    // MARK: 按站点组装

    CardContent Build()
    {
        var session = _station.Session;
        var written = _station.Kind == CareerStationKind.Written;
        var canReject = _application.Text("offer_status") == "none";
        List<Act> reject = canReject ? [new Act("没通过", new CareerDeckAction.Reject(), PDButton.Kind.Reject, _busy)] : [];
        var isLast = _deck.Stations.Count > 0 && _deck.Stations[^1].Id == _station.Id;
        var ended = !_viewing && !_station.Current && isLast ? _deck.Ended : null;
        var source = CareerDeck.Source(_application);
        List<CareerThumb> FromPrevious()
        {
            if (_previous is not { Kind: CareerStationKind.Interview } previous) return [];
            return new[] { WeakThumb(previous), PreviousRecordThumb(previous) }.OfType<CareerThumb>().ToList();
        }

        if (ended is not null)
        {
            var reviewed = _deck.Stations.Where(x => CareerDeck.HasReview(x.Session)).ToList();
            var copy = ended.Kind switch
            {
                CareerDeckEndedKind.Rejected => ("没通过", "没通过", "red", "记录会一直保留，复盘可以在之后的投递里继续参考。"),
                CareerDeckEndedKind.Accepted => ("已接受", "接受了 Offer", (string?)null, "这条投递完成了。记录会一直保留，复盘可以在之后的求职里参考。"),
                CareerDeckEndedKind.Withdrew => ("我不继续了", "我不继续了", "gray", $"你在 {Md(ended.At)} 主动结束了这条投递。记录会保留，想继续可以恢复。"),
                CareerDeckEndedKind.Declined => ("已婉拒", "婉拒了 Offer", "gray", "你婉拒了这个 Offer，记录会一直保留。"),
                _ => ("已结束", "已结束", "gray", "这条投递已经结束，记录会一直保留。"),
            };
            var lastSession = _deck.Stations.Reverse().Select(x => x.Session).OfType<JsonNode>().FirstOrDefault();
            var latestReview = reviewed.LastOrDefault()?.Session;
            var actions = new List<Act>();
            if (ended.Kind == CareerDeckEndedKind.Withdrew) actions.Add(new Act("恢复投递", new CareerDeckAction.Reopen(), Disabled: _busy));
            if (ended.Kind == CareerDeckEndedKind.Accepted) actions.Add(new Act("查看 Offer", new CareerDeckAction.EditOffer()));
            if (ended.Kind is CareerDeckEndedKind.Rejected or CareerDeckEndedKind.Other or CareerDeckEndedKind.Declined && lastSession is not null)
                actions.Add(new Act("编辑记录", new CareerDeckAction.Materials(lastSession!.Text("id"))));
            actions.Add(new Act("查看复盘", new CareerDeckAction.Review(latestReview), PDButton.Kind.Primary, reviewed.Count == 0));
            return new CardContent(
                _deck.Stations.Count > 0 ? _deck.Stations[^1].Title : _station.Title,
                new Hero(ended.At, copy.Item2, $"{DayLabel(ended.At)} 结束 · 走了 {_deck.Stations.Count} 站 · {_deck.Days} 天", copy.Item4,
                    ended.Kind == CareerDeckEndedKind.Rejected ? "red" : ended.Kind == CareerDeckEndedKind.Accepted ? null : "gray"),
                "这条投递留下的",
                [
                    latestReview is { } review
                        ? new CareerThumb("reviews", "复盘", $"{reviewed.Count} 篇", new CareerThumb.Preview.Text(null, ReviewHeadline(review) ?? "复盘已生成", true), () => _act(new CareerDeckAction.Review(review)))
                        : new CareerThumb("reviews", "复盘", "没有", new CareerThumb.Preview.Empty("sparkle", "这条投递没有复盘", [])),
                    ended.Kind == CareerDeckEndedKind.Accepted
                        ? Info("start", "入职", [("日期", DotDate(_application.Text("offer_start_on"))), ("地点", _application.Text("offer_base_location"))])
                        : Info("last", "最后一站", [("站", _station.Short), ("时间", Date(lastSession, "start_at") is { } at ? DayLabel(at) : null)]),
                    Info("materials", "资料", [("资料", $"{_materialsCount} 份"), ("投递简历", _application.Text("resume_title_snapshot"))], open: new CareerDeckAction.AllMaterials()),
                ],
                actions, copy.Item1, copy.Item3);
        }

        if (_station.Kind == CareerStationKind.Apply && _deck.Pending)
        {
            var created = CareerApplication.Date(_application.Text("created_at")) ?? _station.Start;
            return new CardContent(_station.Title,
                new Hero(created, "选一份简历投递", Join($"{Md(created)} 从岗位看板导入", Waited(CareerDeckFormat.DayCount(created, _now))),
                    "投递后记下时间和渠道，之后每一站都接在后面。", "gray"),
                "投递前",
                [ResumeThumb(pending: true), JobThumb(), Info("source", "岗位来源", [("来源", source), ("导入", $"{Md(created)} {Clock(created)}")])],
                [new Act("编辑岗位", new CareerDeckAction.EditJob()), new Act("记录投递", new CareerDeckAction.RecordApplied(), PDButton.Kind.Primary, _busy)],
                "待投递", "gray");
        }
        if (_station.Kind == CareerStationKind.Apply)
        {
            return new CardContent(_station.Title,
                new Hero(_station.Start, source is { } via ? $"通过{via}投递" : "已投递", $"{DayLabel(_station.Start)} {Clock(_station.Start)} 投递", "之后的每一站都接在后面。"),
                "投递信息",
                [ResumeThumb(), Info("channel", "投递渠道", [("渠道", source), ("时间", $"{Md(_station.Start)} {Clock(_station.Start)}")], open: new CareerDeckAction.EditDelivery()),
                 Info("notes", "备注", [("备注", _application.Text("notes"))], open: new CareerDeckAction.EditDelivery())],
                [new Act("编辑", new CareerDeckAction.EditDelivery())],
                "已投递");
        }
        if (_station.Kind == CareerStationKind.Screening && !_viewing)
        {
            var applied = CareerApplication.Date(_application.Text("applied_at")) ?? _station.Start;
            return new CardContent(_station.Title,
                new Hero(applied, "等待简历筛选", Join($"{DayLabel(applied)} 投递", Waited(CareerDeckFormat.DayCount(_station.Start, _now))),
                    "收到笔试、面试邀请或拒信时，在这里推进。"),
                "投递信息",
                [ResumeThumb(), JobThumb(),
                 Info("channel", "投递渠道", [("渠道", source), ("时间", CareerApplication.Date(_application.Text("applied_at")) is { } at ? $"{Md(at)} {Clock(at)}" : null)], open: new CareerDeckAction.EditDelivery())],
                [new Act("补充投递信息", new CareerDeckAction.EditDelivery()), new Act("推进到下一步", new CareerDeckAction.Advance(), PDButton.Kind.Primary, _busy)],
                "等结果");
        }
        if (_station.Kind == CareerStationKind.Oc)
        {
            var at = CareerApplication.Date(_application.Text("oc_communicated_at")) ?? _station.Start;
            var salary = _application.Text("oc_salary_text").NonEmpty();
            return new CardContent(_station.Title,
                new Hero(at, salary ?? "口头意向", $"{DayLabel(at)} 沟通 · 以正式 Offer 为准", salary is not null ? "口头沟通的薪资" : "已收到口头意向，等待正式 Offer"),
                "OC 信息",
                [Info("start", "入职时间", [("入职", _application.Text("oc_start_text"))]), Info("contact", "沟通人", [("沟通人", _application.Text("oc_contact"))]),
                 Info("note", "备注", [("备注", _application.Text("oc_note"))])],
                _station.Current && !_viewing ? [new Act("推进到下一步", new CareerDeckAction.Advance()), new Act("记录 Offer", new CareerDeckAction.RecordOffer(), PDButton.Kind.Primary, _busy)] : [],
                _station.Current ? "等正式 Offer" : "已转正式");
        }
        if (_station.Kind == CareerStationKind.Offer) return OfferContent();
        if (_station.Current && !_viewing && _deck.StageState == "awaiting_schedule" && session is null)
        {
            var since = written || _previous is null || _previous.Kind is CareerStationKind.Apply or CareerStationKind.Screening ? null : $"{_previous.Short}已通过";
            var earlier = written ? [] : FromPrevious();
            return new CardContent(_station.Title,
                new Hero(_station.Start, written ? "还没有定时间" : "还没有约时间", Join($"{RelativeDay(_station.Start)} {Clock(_station.Start)} 收到通知", since),
                    written ? "填上截止时间或作答窗口，会出现在面试日程。" : "约好后填上时间和方式，会同步到面试日程。"),
                written ? "笔试前准备" : earlier.Count == 0 ? "面试前准备" : "之前留下的",
                written ? [JobThumb(), ResumeThumb()] : [.. earlier, .. (earlier.Count < 2 ? [JobThumb()] : Array.Empty<CareerThumb>()), ResumeThumb()],
                [new Act("推进到下一步", new CareerDeckAction.Advance()), new Act("安排时间", new CareerDeckAction.Schedule(), PDButton.Kind.Primary, _busy)],
                "待安排");
        }
        if (session is not null && session.Text("status") == "scheduled" && !_viewing && Date(session, "end_at") is { } finish && finish > _now)
        {
            var start = Date(session, "start_at") ?? _station.Start;
            var open = session.Text("schedule_kind") == "open_window";
            var planStart = Date(session, "answer_plan_start_at");
            var planEnd = Date(session, "answer_plan_end_at");
            var left = open ? CareerDeckFormat.Remaining(finish, _now, "还剩") : CareerDeckFormat.Remaining(start, _now);
            var title = open ? $"{RelativeDay(finish)} {EndClock(finish)} 前完成" : $"{RelativeDay(start)} {Clock(start)} – {Clock(finish)}";
            string?[] sub = open
                ? [RelativeDay(finish) == DayLabel(finish) ? null : $"{DayLabel(finish)} 截止",
                   planStart is { } ps && planEnd is { } pe ? $"计划 {Md(ps)} {Clock(ps)} – {Clock(pe)}" : $"{Md(start)} 起开放，窗口内任选时间完成", left ?? "作答中"]
                : [RelativeDay(start) == DayLabel(start) ? null : DayLabel(start), $"{Minutes(session)} 分钟 · {CareerDeckCopy.Mode(session)}", left ?? "进行中"];
            var weak = written || _previous is null ? null : WeakThumb(_previous);
            var place = (session.Text("mode") == "onsite" && session.Text("location").Length > 0) || session.Text("meeting_url").Length > 0 ? session : null;
            return new CardContent(_station.Title,
                new Hero(open ? finish : start, title, Join(sub), Place: place),
                written ? "笔试前准备" : "面试前准备",
                [PrepThumb(session), weak ?? JobThumb(), FilesThumb(session)],
                [new Act("修改时间", new CareerDeckAction.Reschedule()), new Act(written ? "做完了，记录结果" : "面完了，记录结果", new CareerDeckAction.Advance(), PDButton.Kind.Primary, _busy)],
                "已安排");
        }
        if (session is not null) return SessionContent(session, written, reject);
        if (_station.Current && !_viewing)
        {
            var earlier = FromPrevious();
            return new CardContent(_station.Title,
                new Hero(_station.Start, $"等{_station.Short}的结果", Join($"{DayLabel(_station.Start)} 进入这一站", Waited(CareerDeckFormat.DayCount(_station.Start, _now))),
                    "这一站没有记下时间。收到通知后，在这里推进到下一步。"),
                "之前留下的", [.. earlier, .. (earlier.Count < 2 ? [JobThumb()] : Array.Empty<CareerThumb>()), ResumeThumb()],
                [.. reject, new Act("推进到下一步", new CareerDeckAction.Advance(), PDButton.Kind.Primary, _busy)],
                "等结果");
        }
        var stationFailed = _station.Result == "rejected";
        return new CardContent(_station.Title,
            new Hero(_station.Start, stationFailed ? $"{_station.Short}没通过" : $"{_station.Short}已通过",
                _station.End is { } left2 ? $"{DayLabel(_station.Start)} 进入 · {CareerDeckFormat.DayCount(_station.Start, left2)} 天后进入下一站" : DayLabel(_station.Start),
                "这一站没有记下时间。", stationFailed ? "red" : null),
            "这一站",
            [Info("entered", "进入这一站", [("日期", $"{Md(_station.Start)} {Clock(_station.Start)}")]),
             Info("left", "进入下一站", [("日期", _station.End is { } e1 ? $"{Md(e1)} {Clock(e1)}" : null)]),
             Info("days", "用时", [("用时", _station.End is { } e2 ? $"{CareerDeckFormat.DayCount(_station.Start, e2)} 天" : null)])],
            [],
            stationFailed ? "没通过" : "已通过", stationFailed ? "red" : null);
    }

    CardContent OfferContent()
    {
        var received = _application.Text("offer_status") != "none";
        var due = CareerFormat.OfferDate(_application.Text("offer_reply_due_on"));
        var salary = Money(_application.Display("offer_salary"));
        var benefits = _application.Text("offer_benefits_description");
        var match = Regex.Match(benefits, @"(\d{2})\s*薪");
        int? months = match.Success ? int.Parse(match.Value[..2], CultureInfo.InvariantCulture) : null;
        var receivedOn = CareerFormat.OfferDate(_application.Text("offer_received_on")) ?? _station.Start;
        int? daysLeft = due is { } d ? CareerFormat.Days(_now, d) : null;
        var period = _application.Text("offer_salary_period");
        string? yearly = salary is not null && period != "year" && months is { } m && double.TryParse(_application.Display("offer_salary"), NumberStyles.Float, CultureInfo.InvariantCulture, out var amount)
            ? $"年包约 {Math.Round(amount * m / 1000, MidpointRounding.AwayFromZero) / 10} 万" : null;
        var materials = _application.Items("offer_materials");
        var note = Join(period == "year" ? "年薪" : period == "month" ? "月薪" : null, yearly,
            _application.Text("offer_probation").NonEmpty() is { } probation ? $"试用期 {probation}" : null).NonEmpty() ?? "薪资可以在编辑 Offer 里补上";
        var sub = due is { } dueDay
            ? string.Join(" · ", $"{DayLabel(dueDay)} 答复截止", (daysLeft ?? -1) >= 0 ? $"还剩 {daysLeft} 天" : "已过截止")
            : string.Join(" · ", $"{DayLabel(receivedOn)} 收到", received ? "还没填答复截止" : "等你补充 Offer 信息");
        List<Act> actions = [new Act("编辑 Offer", new CareerDeckAction.EditOffer())];
        if (received) actions.Add(new Act("处理 Offer", new CareerDeckAction.HandleOffer(), PDButton.Kind.Primary, _busy));
        return new CardContent(_station.Title,
            new Hero(due ?? receivedOn, salary is { } s ? s + (months is { } count ? $" × {count}" : "") : "正式 Offer", sub, note),
            "Offer",
            [
                Info("start", "入职", [("日期", DotDate(_application.Text("offer_start_on"))), ("地点", _application.Text("offer_base_location"))], open: new CareerDeckAction.EditOffer()),
                materials.Count == 0
                    ? new CareerThumb("offer-files", "Offer 材料", "还没有", new CareerThumb.Preview.Empty("square.and.arrow.up", "Offer 邮件、合同都可以放这里", [("上传", () => _act(new CareerDeckAction.UploadOffer()))]))
                    : new CareerThumb("offer-files", "Offer 材料", $"{materials.Count} 份", new CareerThumb.Preview.Files(materials.Take(2).Select(x => x.Text("file_name")).ToList(), 0), () => _act(new CareerDeckAction.EditOffer())),
                Info("benefits", "福利", [("福利", benefits)], open: new CareerDeckAction.EditOffer()),
            ],
            actions,
            received ? "待决定" : "信息待补充");
    }

    CardContent SessionContent(JsonNode session, bool written, List<Act> reject)
    {
        var start = Date(session, "start_at") ?? _station.Start;
        var end = Date(session, "end_at") ?? start;
        var open = session.Text("schedule_kind") == "open_window";
        var current = _station.Current && !_viewing;
        var planStart = Date(session, "answer_plan_start_at");
        var planEnd = Date(session, "answer_plan_end_at");
        var when = open
            ? planStart is { } ps && planEnd is { } pe ? $"{Md(ps)} {Clock(ps)} – {Clock(pe)}" : $"{Md(start)} – {Md(end)} 作答窗口"
            : $"{Md(start)} {Clock(start)} – {Clock(end)}";
        var how = open ? null : CareerDeckCopy.Mode(session);
        string status;
        string? tone = null;
        Hero hero;
        if (current)
        {
            var finished = open && planEnd is { } planned && planned < end ? planned : end;
            var days = CareerDeckFormat.DayCount(finished, _now);
            // 场次仍是 scheduled 但已过结束时间：按时间自动视为已面完 / 已做完
            var auto = _application.Text("stage_state") == "scheduled";
            status = days > 0 ? "等结果" : written ? "已做完" : "已面完";
            hero = new Hero(open && planStart is { } a ? a : start,
                days > 0 ? (written ? "做完了，等结果" : "面完了，等结果") : written ? "笔试结果出来了吗？" : "结果出来了吗？",
                Join(when, how, Waited(days)),
                days > 0 ? null : auto ? (written ? "作答时间已过，自动标为已做完。趁记得把题目记下来。" : "面试时间已过，自动标为已面完。趁记得把问题记下来。") : "过了就添加下一阶段，没过也在这里标记。");
        }
        else
        {
            int? resultDays = _station.End is { } stationEnd ? CareerDeckFormat.DayCount(end, stationEnd) : null;
            var failed = _station.Result == "rejected";
            status = failed ? "没通过" : "已通过";
            tone = failed ? "red" : null;
            hero = new Hero(open && planStart is { } a ? a : start, failed ? $"{_station.Short}没通过" : $"{_station.Short}已通过",
                Join(when, how, resultDays is { } r && !failed ? $"{r} 天后出结果" : null), Tone: tone);
        }
        List<CareerThumb> shelf;
        if (written)
        {
            int? used = open ? (planStart is { } ps2 && planEnd is { } pe2 ? Math.Max(1, (int)Math.Round((pe2 - ps2).TotalSeconds / 60, MidpointRounding.AwayFromZero)) : null) : Minutes(session);
            shelf = [WrittenThumb(session), CareerDeck.HasReview(session) ? ReviewThumb(session) : Info("used", "用时", [("用时", used is { } u ? $"{u} 分钟" : null), ("时间", when)]), FilesThumb(session)];
        }
        else shelf = [RecordThumb(session), ReviewThumb(session), FilesThumb(session)];
        var reviewed = CareerDeck.HasReview(session);
        List<Act> actions = current
            ? [.. reject, new Act("添加下一阶段", new CareerDeckAction.Advance(), PDButton.Kind.Primary, _busy)]
            : [new Act("修改面试信息", new CareerDeckAction.Reschedule()),
               new Act(reviewed ? "查看复盘" : written ? "查看笔试题" : "查看面试记录", reviewed ? new CareerDeckAction.Review(session) : new CareerDeckAction.Materials(session.Text("id")), PDButton.Kind.Primary)];
        return new CardContent(_station.Title, hero, current ? (written ? "笔试题与复盘" : "面试记录与复盘") : "这一站留下的", shelf, actions, status, tone);
    }
}
