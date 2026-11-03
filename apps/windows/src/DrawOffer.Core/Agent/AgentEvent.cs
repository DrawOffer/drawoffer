using System.Text.Json;
using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;

namespace DrawOffer.Core.Agent;

/// <summary>一条 SSE 事件：`event:` 名称与 `data:` JSON（Mac `Agent.swift` 的 `AgentEvent`）。</summary>
public sealed record AgentEvent(string Type, JsonNode? Data)
{
    public bool IsTerminal => Type is "run.completed" or "run.failed" or "run.cancelled";

    public static readonly IReadOnlySet<string> Known = new HashSet<string>
    {
        "user.message.accepted", "user.message.applied", "user.message.rejected", "assistant.message.completed",
        "run.started", "run.phase", "assistant.activity.delta", "assistant.activity.status", "assistant.activity.clear", "assistant.delta",
        "clarification.requested", "tool.started", "tool.completed", "proposal.created", "run.completed", "run.failed", "run.cancelled",
    };

    /// <summary>
    /// 解析一个以空行结尾的 SSE 帧；缺少字段、未知事件或 JSON 损坏时返回 null（忽略单条，不中断整条流）。
    /// 与 Swift 相同：按 `"\n"` 字素切行（`"\r\n"` 是一个字素，不会被切开），同名字段以最后一行为准；
    /// data 为 JSON `null` 时 Data 为 null，但事件仍然有效。
    /// </summary>
    public static AgentEvent? Parse(string frame)
    {
        string? name = null, payload = null;
        foreach (var line in SwiftCompat.SplitCharacters(frame, "\n", omitEmpty: false))
        {
            if (SwiftCompat.HasPrefix(line, "event: ")) name = SwiftCompat.DropFirst(line, 7);
            else if (SwiftCompat.HasPrefix(line, "data: ")) payload = SwiftCompat.DropFirst(line, 6);
        }
        if (name is null || !Known.Contains(name) || payload is null) return null;
        return TryDecode(payload, out var value) ? new AgentEvent(name, value) : null;
    }

    /// <summary>
    /// 与 Swift `JSONDecoder` 对齐的 JSON 读取：允许数组/对象末尾多一个逗号，拒绝注释；
    /// 重复键时 System.Text.Json 会抛异常，而 Swift 保留第一个——这里改成保留第一个。
    /// </summary>
    static bool TryDecode(string payload, out JsonNode? value)
    {
        value = null;
        try
        {
            var options = new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Disallow };
            using var document = JsonDocument.Parse(payload, options);
            value = Convert(document.RootElement);
            return true;
        }
        catch (JsonException) { return false; }
        catch (ArgumentException) { return false; }
        catch (FormatException) { return false; }
        catch (OverflowException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    static JsonNode? Convert(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var obj = new JsonObject();
                foreach (var property in element.EnumerateObject())
                    if (!obj.ContainsKey(property.Name)) obj[property.Name] = Convert(property.Value);
                return obj;
            case JsonValueKind.Array:
                var array = new JsonArray();
                foreach (var item in element.EnumerateArray()) array.Add(Convert(item));
                return array;
            case JsonValueKind.String: return JsonValue.Create(element.GetString());
            case JsonValueKind.Number:
                // Swift 解成 Double：溢出（1e400）时解码失败。
                var number = element.GetDouble();
                if (!double.IsFinite(number)) throw new OverflowException();
                return JsonValue.Create(number);
            case JsonValueKind.True: return JsonValue.Create(true);
            case JsonValueKind.False: return JsonValue.Create(false);
            default: return null;
        }
    }
}

/// <summary>Mac `AgentRequest.errorMessage`：AI 助手请求失败时给用户看的中文说明。</summary>
public static class AgentErrors
{
    static readonly Dictionary<string, string> Messages = new()
    {
        ["AGENT_NOT_READY"] = "AI 助手暂未开放，请稍后再试。",
        ["LLM_MODEL_NOT_CONFIGURED"] = "AI 模型尚未配置，请稍后再试。",
        ["AGENT_SESSION_ARCHIVED"] = "这个对话已归档，请新建对话。",
        ["AGENT_RUN_IN_PROGRESS"] = "上一条回复还在生成，请稍候。",
        ["AGENT_STREAM_INCOMPLETE"] = "回复中断了，可以刷新对话查看结果。",
        ["AGENT_PROPOSAL_CONFLICT"] = "简历已变化，这条修改建议无法直接应用。",
        ["AGENT_PROPOSAL_EXPIRED"] = "修改建议已过期，请重新生成。",
        ["DESKTOP_ROUTE_FORBIDDEN"] = "当前服务尚未开放桌面端 AI 助手，请在 Web 使用。",
    };

    /// <summary>
    /// 401（或错误码为 UNAUTHORIZED）→ 登录失效；不是 ApiException → 连接中断；
    /// 已知错误码 → 对应文案；其余 5xx → 暂时不可用；其余 → 带错误码的“操作没有完成”。
    /// </summary>
    public static string Message(Exception error)
    {
        if (error is not ApiException api) return "连接中断，回复结果尚未确认。可以刷新对话查看。";
        if (api.Status == System.Net.HttpStatusCode.Unauthorized || api.Code == "UNAUTHORIZED") return "登录已失效，请重新登录。";
        if (Messages.TryGetValue(api.Code, out var message)) return message;
        return (int)api.Status >= 500 ? "AI 助手暂时不可用，请稍后重试。" : $"操作没有完成（{api.Code}）。";
    }
}
