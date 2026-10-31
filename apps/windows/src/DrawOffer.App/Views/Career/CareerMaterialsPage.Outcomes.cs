using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerMaterialsPage
{
    (string Hint, List<Outcome> Items) Outcomes(CareerStation station, JsonNode? detail)
    {
        if (station.Kind == CareerStationKind.Apply)
        {
            var resume = _application.Text("resume_id").Length > 0;
            var applied = CareerApplication.Date(_application.Text("applied_at").NonEmpty() ?? _application.Text("created_at"));
            var channel = _application.Text("applied_channel");
            var resumeCard = resume
                ? new Outcome("resume", "doc.text", "blue", "投递简历")
                {
                    State = (_application.Text("resume_title_snapshot").NonEmpty() ?? "投递简历", false),
                    Meta = $"{CareerDeckFormat.MonthDay(applied)}{(channel.Length == 0 ? " " : $" · {channel} ")}投递时使用", Actions = [("打开 ›", false, _openResume)],
                }
                : new Outcome("resume", "doc.text", "plain", "投递简历") { State = ("没有记录", true), Meta = "记录投递时可以选一份简历" };
            var jobCard = _application.Text("job_description_id").Length == 0
                ? new Outcome("job", "briefcase", "plain", "岗位 JD") { State = ("原岗位资料已不可用", true) }
                : new Outcome("job", "briefcase", "plain", "岗位 JD") { State = (_application.Text("job_title_snapshot"), false), Meta = _application.Text("company_name_snapshot"), Actions = [("查看 ›", false, _openJob)] };
            return ("投递时用的简历和岗位", [resumeCard, jobCard]);
        }
        if (station.Session is not { } summary || detail is null) return ("", []);
        var sessionId = summary.Text("id");
        var session = detail.Get("session") ?? summary;
        if (station.Kind == CareerStationKind.Written)
        {
            var written = session.Items("written_questions");
            var marked = written.Count(x => x.Text("correctness").Length > 0);
            return ("笔试题目和做题后的笔记", [written.Count == 0
                ? new Outcome("written", "list.bullet", "purple", "笔试题") { Body = "还没有题目。上传题目文档或截图转成的 PDF，AI 读出题目后可以逐题标答对 / 答错。", Actions = [("上传题目文档", true, () => _add(summary))], Wide = true }
                : new Outcome("written", "list.bullet", "purple", "笔试题")
                {
                    Number = ($"{written.Count}", "道题"), Meta = marked > 0 ? $"{marked} 道标了答得怎么样" : "还没标答得怎么样，点开逐题标答对 / 答错",
                    Actions = [(_writtenOpen ? "收起" : "查看题目 ›", false, () => { _writtenOpen = !_writtenOpen; Render(); })], Wide = true,
                }]);
        }
        var questions = InterviewRecord.Parse(session.Text("questions_markdown"));
        var transcriptions = session.Items("transcriptions");
        var converting = transcriptions.Any(x => x.Text("status") is "queued" or "running");
        var assets = detail.Items("assets");
        var source = assets.FirstOrDefault(asset => transcriptions.Any(x => x.Text("dataset_id") == asset.Text("id") && x.Text("status") == "succeeded" && !x.Bool("pending_replace")));
        var record = new Outcome("record", "text.alignleft", "blue", "面试记录");
        if (_splitting.Contains(sessionId))
        {
            record.State = ("正在拆成问题", false); record.Meta = "一般 20–40 秒，可以先去做别的"; record.Actions = [("查看进度 ›", false, () => _openRecord(sessionId, CareerRecordPage.Mode.Record))];
        }
        else if (questions.Count > 0)
        {
            var answered = InterviewRecord.Answered(questions);
            record.Number = ($"{questions.Count}", "道题");
            record.Meta = string.Join(" · ", new[] { answered == questions.Count ? $"{answered} 道都记了回答" : $"{answered} 道记了回答", source is null ? null : "来自 " + source.Text("original_file_name") }.OfType<string>());
            record.Actions = [("重新粘贴", false, () => _openRecord(sessionId, CareerRecordPage.Mode.Paste)), ("查看 ›", false, () => _openRecord(sessionId, CareerRecordPage.Mode.Record))];
        }
        else if (converting) { record.State = ("录音转文字中", false); record.Meta = "转好后自动整理成面试记录，这里会更新"; }
        else
        {
            record.State = ("还没有", true); record.Meta = "上传录音或回忆笔记会自动整理；也可以直接粘贴文字"; record.Actions = [("粘贴文字", false, () => _openRecord(sessionId, CareerRecordPage.Mode.Paste))];
        }
        var review = new Outcome("review", "sparkle", "purple", "AI 复盘");
        if (summary.Text("review_status") == "generating") { review.Body = "正在复盘，一般 1 分钟左右，好了这里会更新。"; review.Actions = [("打开 ›", false, () => _openReview(summary))]; }
        else if (summary.Text("review_status") == "failed") { review.Body = "这次没生成出来，可以再试一次。"; review.Actions = [("再试一次", true, () => _generateReview(summary))]; }
        else if (CareerDeck.HasReview(summary)) { review.State = (Headline(summary), false); review.Meta = "点开看每道题的分析"; review.Actions = [("查看 ›", false, () => _openReview(summary))]; }
        else if (questions.Count > 0)
        {
            review.Body = $"用这一轮 {questions.Count} 道题的面试记录，逐题点评回答、标出薄弱的地方，并列出下一轮要准备的内容。";
            review.Meta = "大约 1 分钟"; review.Actions = [("生成复盘", true, () => _generateReview(summary))];
        }
        else { review.Body = "有了面试记录就能生成：逐题点评、标出薄弱的地方，并列出下一轮要准备的内容。"; review.Meta = "先把这一轮的问题记进面试记录"; }
        return ("录音和笔记整理出来的东西", [record, review]);
    }

    static string Headline(JsonNode session)
    {
        var report = session.Get("review_report");
        var text = report.Number("schema_version") == 2 ? report.Text("headline").NonEmpty() ?? "每道题都答到了位"
            : report.Text("summary").Trim().NonEmpty() ?? session.Text("review_summary").Trim().NonEmpty() ?? "复盘已生成";
        return Count(text) > 22 ? Prefix(text, 22) + "…" : text;
    }

    // MARK: 资料缩略图

    static string FileSize(long bytes)
    {
        // `ByteCountFormatter.string(fromByteCount:countStyle: .file)`：十进制单位，KB 取整，MB 起保留一位
        if (bytes < 1000) return bytes == 0 ? "Zero KB" : $"{bytes} bytes";
        string[] units = ["KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = -1;
        do { value /= 1000; unit++; } while (value >= 1000 && unit < units.Length - 1);
        return unit == 0 ? $"{Round(value):0} {units[unit]}" : $"{value:0.#} {units[unit]}";
    }

    FrameworkElement Tile(JsonNode asset, JsonNode detail)
    {
        var name = asset.Text("original_file_name");
        var media = asset.Text("asset_type") != "document";
        var ext = name.Contains('.') ? name.Split('.', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.ToUpperInvariant() ?? "" : "";
        var transcription = detail.Get("session").Items("transcriptions").FirstOrDefault(x => x.Text("dataset_id") == asset.Text("id"));
        var status = transcription?.Text("status");
        (string Text, Color Color)? state = !media ? null
            : status is "queued" or "running" ? ("正在转文字", PD.BlueText)
            : status == "failed" ? ("没能转成文字", Hex(0xA35A12))
            : status == "succeeded" && transcription.Bool("pending_replace") ? ("已转好，还没替换记录", PD.Mute)
            : status == "succeeded" ? ("已转写", PD.Mute) : null;
        var kind = media ? (asset.Text("asset_type") == "video" ? "视频" : "录音") : ext is "MD" or "TXT" ? "笔记" : "文档";
        var ms = asset.Integer("duration_ms");
        var size = media ? (ms > 0 ? $"{Two(ms / 1000 / 60)}:{Two(ms / 1000 % 60)}" : null) : FileSize((long)(asset.Number("file_size") ?? 0));
        var preview = new Grid { Height = 120 };
        if (media)
        {
            preview.Background = Brush(0xFDF2E9);
            preview.Children.Add(Wave(asset.Text("id")));
        }
        else
        {
            preview.Background = Brush(0xF7F7F5);
            var lines = new StackPanel { Spacing = 7, Padding = new Thickness(12, 14, 12, 0) };
            for (var index = 0; index < 6; index++)
                lines.Children.Add(new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Brush(0xDCDCD8), Width = index % 3 == 2 ? 40 : double.NaN, HorizontalAlignment = HorizontalAlignment.Stretch }
                    .Also(b => { if (index % 3 == 2) b.HorizontalAlignment = HorizontalAlignment.Left; }));
            var sheet = new Border { Child = lines, Width = 80, Height = 103, CornerRadius = new CornerRadius(6, 6, 0, 0), Background = Brush(V3.White), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center }.Elevate(3);
            preview.Children.Add(sheet);
        }
        if ((media ? size : ext.NonEmpty()) is { } label)
            preview.Children.Add(Label(label, media ? 12 : 10, media ? Hex(0xA35A12) : PD.Mute, Semibold).Also(t => { t.HorizontalAlignment = HorizontalAlignment.Right; t.VerticalAlignment = VerticalAlignment.Bottom; t.Margin = new Thickness(0, 0, 12, 10); }));
        preview.SizeChanged += (_, e) => preview.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        var title = Sans(name, 13, Txt, Medium).Frame(height: 20);
        ToolTipService.SetToolTip(title, name);
        var meta = new TextBlock { FontFamily = SansFamily, FontSize = 11.5, Foreground = Brush(PD.Mute), MinHeight = 17, TextTrimming = TextTrimming.CharacterEllipsis };
        meta.Inlines.Add(new Run { Text = string.Join(" · ", new[] { kind, size }.OfType<string>()) });
        if (state is { } s) meta.Inlines.Add(new Run { Text = " · " + s.Text, Foreground = Brush(s.Color) });
        var footer = VStack(2, title, meta);
        footer.Padding = new Thickness(14, 12, 14, 14);
        var stack = new StackPanel();
        stack.Children.Add(preview);
        stack.Children.Add(footer);
        return new Border { Child = stack, CornerRadius = new CornerRadius(16), Background = Brush(V3.White), BorderBrush = Brush(0xE7E5DF), BorderThickness = new Thickness(1) };
    }

    /// <summary>录音缩略图：按文件 ID 生成稳定的装饰波形，不代表真实音量。</summary>
    static UIElement Wave(string seed)
    {
        var value = seed.EnumerateRunes().Aggregate(17, (sum, rune) => sum + rune.Value);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2.5, Height = 56, Padding = new Thickness(16, 0, 16, 0), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (var index = 0; index < 36; index++)
        {
            value = (value * 9301 + 49297) % 233280;
            var envelope = 0.4 + 0.6 * Math.Sin(index / 36.0 * Math.PI);
            var height = Round(8 + envelope * value / 233280 * 44);
            row.Children.Add(new Border { Width = 2.5, Height = height, CornerRadius = new CornerRadius(1.25), Background = Brush(0xE8853D), VerticalAlignment = VerticalAlignment.Center });
        }
        Hidden(row);
        return row;
    }

    // MARK: 笔试题

    static UIElement Written(JsonNode detail)
    {
        var questions = detail.Get("session").Items("written_questions");
        var marked = questions.Count(x => x.Text("correctness").Length > 0);
        var chip = new Border
        {
            Child = Sans($"{questions.Count} 道题 · {marked} 道标了答得怎么样", 11, PD.BlueText, Medium).Align(v: VerticalAlignment.Center),
            Padding = new Thickness(8, 0, 8, 0), Height = 20, CornerRadius = new CornerRadius(6), Background = Brush(PD.Tint), HorizontalAlignment = HorizontalAlignment.Left,
        };
        var head = VStack(6, Serif("笔试题", 17), chip);
        head.Padding = new Thickness(20, 18, 20, 12);
        var stack = new StackPanel();
        stack.Children.Add(head);
        stack.Children.Add(Divider(Hex(0xECEAE4)));
        if (questions.Count == 0) stack.Children.Add(Sans("还没有题目。上传题目文档后可以逐题查看。", 12.5, PD.Mute).Wrap().Pad(20, 20, 20, 20));
        else
        {
            var list = new StackPanel { Padding = new Thickness(20, 0, 20, 8) };
            foreach (var item in questions)
            {
                var mark = item.Text("correctness") switch { "correct" => "答对", "wrong" => "答错", "unsure" => "不确定", _ => "先不标" };
                var entry = VStack(4,
                    Sans($"{item.Display("question_no")}. {item.Text("question_text")}", 13.5, Txt, Medium).Wrap(),
                    Sans("我的答案：" + (item.Text("answer").NonEmpty() ?? "没记答案。") + " · " + mark, 12.5, PD.Body).Wrap());
                list.Children.Add(new Border { Child = entry, Padding = new Thickness(0, 10, 0, 10), BorderBrush = Brush(0xF1F0EC), BorderThickness = new Thickness(0, 0, 0, 1) });
            }
            stack.Children.Add(list);
        }
        return new Border
        {
            Child = stack, CornerRadius = new CornerRadius(16), Background = Brush(V3.White), BorderBrush = Brush(0xCDDCF5), BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 16, 0, 0),
        }.Elevate(10);
    }
}
