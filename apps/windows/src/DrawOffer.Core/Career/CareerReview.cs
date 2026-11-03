using DrawOffer.Core.Api;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
namespace DrawOffer.Core.Models;

/// <summary>Web `reviewReport.ts` 的原生移植：AI 复盘报告 v1 / v2 的投影。</summary>
public static class CareerReview
{
    public static bool IsV2(JsonNode? report) => CareerJson.OptionalInteger(report, "schema_version") == 2;

    /// <summary>两版报告统一为 0–100 总分；v1 存的是 0–10 平均分。</summary>
    public static int? Score100(JsonNode? report)
    {
        if (report is null) return null;
        if (IsV2(report)) return report.Number("total_score") is { } total ? (int)SwiftText.Rounded(total) : null;
        return report.Number("overall_score") is { } overall ? (int)SwiftText.Rounded(overall * 10) : null;
    }

    public static CareerChip? Grade(int? score)
    {
        if (score is not { } value) return null;
        if (value >= 85) return new("优秀", CareerTone.Green);
        if (value >= 70) return new("良好", CareerTone.Green);
        if (value >= 60) return new("合格", CareerTone.Orange);
        return new("待提升", CareerTone.Red);
    }

    public static string DimensionLabel(string key) => key switch
    {
        "professional_depth" => "专业深度", "motivation_fit" => "动机与稳定性", "structure" => "表达结构", "job_fit" => "岗位匹配",
        "resume_consistency" => "经历可信度", "communication" => "沟通与应变", _ => key,
    };

    public static string CategoryLabel(string key) => key switch { "technical" => "技术题", "project" => "项目题", "behavioral" => "行为题", "hr" => "HR 题", _ => key };

    public static CareerChip Verdict(string level) => level switch
    {
        "likely_pass" => new("大概率通过", CareerTone.Green), "promising" => new("有希望通过", CareerTone.Blue),
        "at_risk" => new("存在风险", CareerTone.Orange), "likely_fail" => new("大概率未通过", CareerTone.Red), _ => new("存在风险", CareerTone.Orange),
    };

    public static string ConfidenceLabel(string value) => value == "high" ? "判断把握 高" : value == "medium" ? "判断把握 中" : "判断把握 低";

    /// <summary>单题得分色调。</summary>
    public static CareerTone ScoreTone(double? score) => score is not { } value ? CareerTone.Gray : value >= 75 ? CareerTone.Green : value >= 50 ? CareerTone.Orange : CareerTone.Red;

    /// <summary>列表和时间线行里的简短状态。</summary>
    public static string StatusText(JsonNode session)
    {
        if (session.Bool("review_stale")) return "记录已修改，待重新生成";
        if (session.Text("review_status") == "generating") return "正在生成…";
        if (session.Get("review_report") is { } report) return Score100(report) is { } score ? $"复盘 {score}" : "已复盘";
        return session.Text("review_status") == "failed" ? "生成失败" : "待复盘";
    }

    /// <summary>0–5 分雷达图的正多边形顶点；null 画在圆心。</summary>
    public static (double X, double Y)[] RadarPoints(IReadOnlyList<double?> values, double radius, double center) =>
        values.Select((value, index) =>
        {
            var angle = -Math.PI / 2 + index * 2 * Math.PI / Math.Max(values.Count, 1);
            var r = (value ?? 0) / 5 * radius;
            return (center + r * Math.Cos(angle), center + r * Math.Sin(angle));
        }).ToArray();

    /// <summary>每个维度条下方的说明。</summary>
    public static string DimensionNote(JsonNode item)
    {
        if (!item.Bool("assessed"))
            return item.Text("key") switch { "job_fit" => "没有岗位要求，不评这一项", "resume_consistency" => "没有关联简历，不评这一项", _ => "证据不足，不评这一项" };
        var weight = (int)SwiftText.Rounded((item.Number("weight") ?? 0) * 100);
        return string.Join(" · ", new[] { $"权重 {weight}%", item.Text("comment").Length == 0 ? null : item.Text("comment") }.OfType<string>());
    }

    public static string Basis(JsonNode report)
    {
        var basis = report.Get("basis");
        var snippets = basis.Integer("material_snippets");
        var downgraded = basis.Integer("downgraded_quotes");
        return string.Join(" · ", new[]
        {
            basis.Text("transcript_source") == "transcription" ? "录音转写文字稿" : "文字稿",
            basis.Text("resume_title").Length == 0 ? "未关联简历" : "投递简历 " + basis.Text("resume_title"),
            basis.Bool("has_job") ? "岗位要求" : "无岗位要求",
            snippets > 0 ? $"资料库片段 {snippets} 段" : null,
            basis.Text("material_mode") == "local" ? "资料召回已降级为本地匹配" : null,
            downgraded > 0 ? $"{downgraded} 处判断因原句不符被降级" : null,
            "评分规则 " + report.Text("rubric_version"),
        }.OfType<string>());
    }

    /// <summary>按题目（`question_key`）索引的复盘笔记，以及题目已不在报告里的笔记。</summary>
    public static (Dictionary<string, JsonNode> ByKey, List<JsonNode> Unmatched) Notes(JsonNode session, JsonNode report)
    {
        var notes = session.Items("review_question_notes");
        var keys = report.Items("questions").Select(x => x.Text("key")).ToHashSet();
        var byKey = new Dictionary<string, JsonNode>();
        foreach (var note in notes) byKey[note.Text("question_key")] = note;
        return (byKey, notes.Where(x => !keys.Contains(x.Text("question_key"))).ToList());
    }
}

/// <summary>与 Web `StageDetailPage.tsx` 共用的阶段详情辅助。</summary>
public static class CareerTranscript
{
    public sealed record Line(string? Speaker, string Text)
    {
        public bool IsMe => Speaker is { } speaker && SwiftText.Lower(speaker) is "我" or "me" or "候选人";
    }

    static readonly string[] Speakers = ["面试官", "HR", "我", "候选人", "Interviewer", "Me"];

    static bool Blank(string c) => c is " " or "\t";

    /// <summary>形如「说话人：内容」的行读成对话；其他保持普通段落。</summary>
    public static List<Line> Lines(string markdown) =>
        markdown.Split('\n').Select(SwiftText.TrimWhitespaces).Where(x => x.Length > 0).Select(line =>
        {
            foreach (var speaker in Speakers)
            {
                if (!SwiftText.HasPrefix(SwiftText.Lower(line), SwiftText.Lower(speaker))) continue;
                var count = SwiftText.Count(speaker);
                var rest = SwiftText.Elements(line).Skip(count).SkipWhile(Blank).ToArray();
                if (rest.Length == 0 || rest[0] is not (":" or "：")) continue;
                rest = rest.Skip(1).SkipWhile(Blank).ToArray();
                if (rest.Length == 0) continue;
                return new Line(SwiftText.Prefix(line, count), string.Concat(rest));
            }
            return new Line(null, line);
        }).ToList();

    /// <summary>编号（`1.` `1)` `1、`）或项目符号（`-` `*`）开头的行，去掉标记后的内容。</summary>
    public static string? QuestionText(string line)
    {
        var rest = SwiftText.Elements(SwiftText.TrimWhitespaces(line)).ToList();
        if (rest.Count > 0 && rest[0] is "-" or "*") rest.RemoveAt(0);
        else
        {
            var digits = rest.TakeWhile(c => c.Length == 1 && char.IsAscii(c[0]) && SwiftText.IsNumber(c)).Count();
            if (digits == 0) return null;
            rest.RemoveRange(0, digits);
            if (rest.Count == 0 || rest[0] is not ("." or ")" or "、")) return null;
            rest.RemoveAt(0);
        }
        if (rest.Count == 0 || !Blank(rest[0])) return null;
        var text = string.Concat(rest.SkipWhile(Blank));
        return text.Length == 0 ? null : text;
    }

    public static List<string> Questions(string markdown) => markdown.Split('\n').Select(QuestionText).OfType<string>().ToList();

    public static string TranscriptionError(string code) => code switch
    {
        "INTERVIEW_TRANSCRIPTION_NOT_CONFIGURED" => "语音识别还没有配置，请联系管理员。",
        "INTERVIEW_TRANSCRIPTION_STORAGE_UNAVAILABLE" => "录音暂时无法交给语音识别服务，请稍后重试。",
        "INTERVIEW_TRANSCRIPTION_FORMAT_UNSUPPORTED" => "录音格式无法识别，请换成 mp3 或 m4a 后重新上传。",
        "INTERVIEW_TRANSCRIPTION_DOWNLOAD_FAILED" => "语音识别服务没能读取录音，请稍后重试。",
        "INTERVIEW_TRANSCRIPTION_AUDIO_TOO_LONG" => "录音太长，暂不支持转写。",
        "INTERVIEW_TRANSCRIPTION_EMPTY" => "录音里没有识别到有效的语音。",
        "INTERVIEW_TRANSCRIPTION_TIMEOUT" => "转写超时，请重试。",
        _ => "转写失败，请重试。",
    };

    public static string? ImportError(string code) => code switch
    {
        "INTERVIEW_QUESTIONS_NOT_FOUND" => "没有识别到题目，请检查内容后重试。",
        "INTERVIEW_IMPORT_MODEL_NOT_CONFIGURED" => "识别模型还没有配置，请联系管理员。",
        "INTERVIEW_IMPORT_TEXT_TOO_LONG" => "内容超过 20,000 字，请分批导入。",
        "INTERVIEW_IMPORT_IMAGE_TOO_LARGE" => "每张截图不能超过 5MB。",
        "INTERVIEW_IMPORT_IMAGE_INVALID" => "截图无法识别，请上传 png、jpg 或 webp 图片。",
        "INTERVIEW_IMPORT_IMAGE_COUNT" => "一次最多上传 5 张截图。",
        "INTERVIEW_IMPORT_DATASET_NOT_READY" => "这份文件还没有解析完成，请稍后再试。",
        "INTERVIEW_IMPORT_TIMEOUT" => "识别超时，请稍后重试。",
        _ => null,
    };

    /// <summary>阶段详情页的状态标签。</summary>
    public static CareerChip Status(JsonNode session, JsonNode application, DateTimeOffset? now = null)
    {
        var status = CareerSessions.EffectiveStatus(session, now);
        if (status == "cancelled") return new("已取消", CareerTone.Gray);
        if (session.Text("round_result") == "passed") return new("已通过", CareerTone.Green);
        if (session.Text("round_result") == "rejected") return new("未通过", CareerTone.Red);
        if (status == "scheduled") return new("已安排", CareerTone.Blue);
        return application.Text("status") == "active" ? new("等待结果", CareerTone.Orange) : new("已结束", CareerTone.Gray);
    }

    /// <summary>这段录音的转写任务（如有）。</summary>
    public static JsonNode? Transcription(JsonNode session, string datasetId) => session.Items("transcriptions").FirstOrDefault(x => x.Text("dataset_id") == datasetId);
}

/// <summary>需要上传文件的求职接口的 multipart 请求体。</summary>
public static class CareerUpload
{
    public const int MaxImages = 5;
    public const int MaxImageBytes = 5 * 1024 * 1024;

    /// <summary>
    /// `written-questions:extract`：`{source: text|dataset|images, text?, dataset_id?, images?: [{base64, content_type}]}`。
    /// Mac 的 `APIError.invalidResponse` 对应 <see cref="InvalidDataException"/>，`APIError.server(400, code)` 对应 <see cref="ApiException"/>。
    /// </summary>
    public static (byte[] Body, string ContentType) WrittenImport(JsonNode body)
    {
        var boundary = "DrawOffer-" + Guid.NewGuid().ToString("D").ToUpperInvariant();
        var data = new MemoryStream();
        void Append(string text) { var bytes = Encoding.UTF8.GetBytes(text); data.Write(bytes, 0, bytes.Length); }
        void Field(string name, string value) => Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n");
        var source = body.Text("source");
        if (source is not ("text" or "dataset" or "images")) throw new InvalidDataException();
        Field("source", source);
        switch (source)
        {
            case "text": Field("text", body.Text("text")); break;
            case "dataset":
                if (!DatasetRequest.Id(body.Text("dataset_id"))) throw new InvalidDataException();
                Field("dataset_id", body.Text("dataset_id"));
                break;
            default:
                var images = body.Items("images");
                if (images.Count == 0 || images.Count > MaxImages) throw new ApiException(HttpStatusCode.BadRequest, "INTERVIEW_IMPORT_IMAGE_COUNT");
                for (var index = 0; index < images.Count; index++)
                {
                    var image = images[index];
                    var type = image.Text("content_type");
                    if (SwiftBase64.Decode(image.Text("base64")) is not { } bytes || bytes.Length > MaxImageBytes) throw new ApiException(HttpStatusCode.BadRequest, "INTERVIEW_IMPORT_IMAGE_TOO_LARGE");
                    var ext = type switch { "image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp", _ => null } ?? throw new ApiException(HttpStatusCode.BadRequest, "INTERVIEW_IMPORT_IMAGE_INVALID");
                    Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"image-{index + 1}.{ext}\"\r\nContent-Type: {type}\r\n\r\n");
                    data.Write(bytes, 0, bytes.Length); Append("\r\n");
                }
                break;
        }
        Append($"--{boundary}--\r\n");
        return (data.ToArray(), $"multipart/form-data; boundary={boundary}");
    }
}
