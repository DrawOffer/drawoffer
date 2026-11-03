using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.Core.Models;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerStationCard
{
    // MARK: 缩略图

    CareerThumb Info(string id, string name, IEnumerable<(string, string?)> rows, string? meta = null, CareerDeckAction? open = null) =>
        new(id, name, meta, new CareerThumb.Preview.Info(rows.Select(r => (r.Item1, r.Item2?.NonEmpty())).ToList()), open is null ? null : () => _act(open));

    CareerThumb ResumeThumb(bool pending = false)
    {
        var title = _application.Text("resume_title_snapshot").NonEmpty();
        CareerThumb.Preview preview = title is not null
            ? new CareerThumb.Preview.Doc(title, [88, 64, 76, 52])
            : new CareerThumb.Preview.Empty("paperclip", pending ? "投递时再选简历" : "还没有关联投递简历", pending ? [] : [("选简历", () => _act(new CareerDeckAction.EditDelivery()))]);
        return new CareerThumb("resume", "投递简历", title ?? (pending ? "投递时选择" : "没有关联"), preview, title is null ? null : () => _act(new CareerDeckAction.EditDelivery()));
    }

    CareerThumb JobThumb()
    {
        var skills = JobSkills();
        var hasJob = _application.Text("job_description_id").Length > 0;
        CareerThumb.Preview preview = skills.Count == 0
            ? new CareerThumb.Preview.Empty("list.bullet", "补上岗位要求，准备和复盘会更准", hasJob ? [("补充", () => _act(new CareerDeckAction.EditJob()))] : [])
            : new CareerThumb.Preview.List(null, skills);
        return new CareerThumb("job", "岗位要求", skills.Count == 0 ? "没填岗位信息" : "来自岗位信息", preview, skills.Count > 0 && hasJob ? () => _act(new CareerDeckAction.EditJob()) : null);
    }

    CareerThumb FilesThumb(JsonNode session)
    {
        var assets = Detail(session).Items("assets");
        var id = session.Text("id");
        CareerThumb.Preview preview = assets.Count == 0
            ? new CareerThumb.Preview.Empty("paperclip", "面经、公司资料都可以放这里", [("添加资料", () => _act(new CareerDeckAction.Materials(id)))])
            : new CareerThumb.Preview.Files(assets.Take(2).Select(x => x.Text("original_file_name")).ToList(), Math.Max(0, assets.Count - 2));
        return new CareerThumb("files", "资料", $"{assets.Count} 份", preview, assets.Count == 0 ? null : () => _act(new CareerDeckAction.Materials(id)));
    }

    CareerThumb PrepThumb(JsonNode session)
    {
        var items = session.Items("prep_items");
        if (items.Count == 0)
        {
            var canGenerate = session.Get("prep_generated_at") is null;
            CareerThumb.Preview preview = _prepBusy
                ? new CareerThumb.Preview.Doc("", [80, 64, 72])
                : new CareerThumb.Preview.Empty("list.bullet", canGenerate ? "按岗位要求和你的简历生成" : "自己列几条要准备的",
                    [canGenerate ? ("生成清单", () => _act(new CareerDeckAction.PrepGenerate(session))) : ("+ 添加", () => _act(new CareerDeckAction.PrepOpen(session)))]);
            return new CareerThumb("prep", "准备清单", _prepBusy ? "生成中…" : "还没有", preview);
        }
        var done = items.Count(x => x.Bool("done"));
        return new CareerThumb("prep", "准备清单", $"完成 {done} / {items.Count}",
            new CareerThumb.Preview.Checks(items.Take(3).Select((item, index) => (item.Text("title"), item.Bool("done"), (Action)(() => _act(new CareerDeckAction.PrepToggle(session, index))))).ToList()),
            () => _act(new CareerDeckAction.PrepOpen(session)));
    }

    CareerThumb? WeakThumb(CareerStation previous)
    {
        if (previous.Session is not { } session || !CareerDeck.HasReview(session)) return null;
        var gaps = ReviewGaps(session);
        CareerThumb.Preview preview = gaps.Count == 0
            ? new CareerThumb.Preview.Text($"{previous.Short}复盘", ReviewHeadline(session) ?? "没有要补的", false)
            : new CareerThumb.Preview.List($"{previous.Short}复盘 · 待加强", gaps);
        return new CareerThumb("weak", "上一面要补的", $"来自{previous.Short}复盘", preview, () => _act(new CareerDeckAction.Review(session)));
    }

    CareerThumb? PreviousRecordThumb(CareerStation previous)
    {
        if (previous.Session is not { } session) return null;
        var list = Questions(session);
        if (list.Count == 0) return null;
        return new CareerThumb("prev-record", $"{previous.Short}面试记录", $"{list.Count} 道题", new CareerThumb.Preview.Qa(list), () => _act(new CareerDeckAction.Materials(session.Text("id"))));
    }

    CareerThumb RecordThumb(JsonNode session)
    {
        var id = session.Text("id");
        var list = Questions(session);
        if (list.Count > 0)
            return new CareerThumb("record", "面试记录", $"{list.Count} 道题 · " + (session.Text("transcript_source") == "transcription" ? "录音转写" : "文字整理"),
                new CareerThumb.Preview.Qa(list), () => _act(new CareerDeckAction.Materials(id)));
        var detailed = Detail(session).Get("session").Get("transcriptions") is JsonArray ? Detail(session).Get("session").Items("transcriptions") : session.Items("transcriptions");
        if (detailed.Any(x => x.Text("status") is "queued" or "running"))
            return new CareerThumb("record", "面试记录", "转写中", new CareerThumb.Preview.Text(null, "正在转成文字", false));
        if (detailed.Any(x => x.Text("status") == "failed"))
            return new CareerThumb("record", "面试记录", "没能整理出来", new CareerThumb.Preview.Empty("mic", "录音没能转成文字",
                [("重新上传", () => _act(new CareerDeckAction.Materials(id))), ("粘贴文字", () => _act(new CareerDeckAction.Materials(id)))]));
        return new CareerThumb("record", "面试记录", "还没有", new CareerThumb.Preview.Empty("mic", "上传录音，或粘贴自己记的内容",
            [("上传录音", () => _act(new CareerDeckAction.Materials(id))), ("粘贴文字", () => _act(new CareerDeckAction.Materials(id)))]));
    }

    CareerThumb ReviewThumb(JsonNode session)
    {
        if (session.Text("review_status") == "generating")
            return new CareerThumb("review", "复盘", "正在复盘", new CareerThumb.Preview.Text(null, "正在逐题看你的回答…", false), () => _act(new CareerDeckAction.Review(session)));
        if (session.Text("review_status") != "failed" && CareerDeck.HasReview(session))
        {
            var gaps = ReviewGaps(session);
            CareerThumb.Preview preview = gaps.Count == 0
                ? new CareerThumb.Preview.Text(null, ReviewHeadline(session) ?? "复盘已生成", true)
                : new CareerThumb.Preview.List(ReviewHeadline(session) ?? "待加强", gaps.Take(2).ToList());
            return new CareerThumb("review", "复盘", "已生成", preview, () => _act(new CareerDeckAction.Review(session)));
        }
        var count = Questions(session).Count;
        if (count > 0)
        {
            var failed = session.Text("review_status") == "failed";
            return new CareerThumb("review", "复盘", failed ? "没生成出来" : "可以生成",
                new CareerThumb.Preview.Empty("sparkle", failed ? "上次没生成出来，可以再试一次" : $"按 {count} 道题的问答，看哪些答得好、哪些要补",
                    [(failed ? "再试一次" : "生成复盘", () => _act(new CareerDeckAction.GenerateReview(session)))]));
        }
        return new CareerThumb("review", "复盘", "等面试记录", new CareerThumb.Preview.Empty("sparkle", "有了面试记录就能生成复盘", []));
    }

    CareerThumb WrittenThumb(JsonNode session)
    {
        var items = Detail(session).Get("session").Get("written_questions") is JsonArray ? Detail(session).Get("session").Items("written_questions") : session.Items("written_questions");
        var id = session.Text("id");
        if (items.Count == 0)
            return new CareerThumb("written", "笔试题", "还没有", new CareerThumb.Preview.Empty("square.and.arrow.up", "上传题目截图或文档，整理成题目", [("添加笔试题", () => _act(new CareerDeckAction.Materials(id)))]));
        var correct = items.Count(x => x.Text("correctness") == "correct");
        return new CareerThumb("written", "笔试题", $"{items.Count} 道 · 答对 {correct}",
            new CareerThumb.Preview.Written(items.Take(3).Select(x => (x.Display("question_no"), x.Text("question_text"), x.Text("correctness"))).ToList()),
            () => _act(new CareerDeckAction.Materials(id)));
    }

    static string Join(params string?[] parts) => string.Join(" · ", parts.OfType<string>());
}
