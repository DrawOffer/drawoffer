using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;

namespace DrawOffer.Core.Session;

/// <summary>侧栏“最近对话”（`GET /api/agent/sessions`），对应 Mac `AgentSessionsModel`。退出或换账号时清空。</summary>
public sealed class AgentSessions
{
    public enum LoadStatus { Idle, Loading, Ready, Error }

    public List<JsonNode> Items { get; private set; } = [];
    public LoadStatus Status { get; private set; } = LoadStatus.Idle;
    /// <summary>正在生成回答的会话：与 Web 一致，生成中不能删除。</summary>
    public HashSet<string> RunningIds { get; } = [];
    public event Action? Changed;
    string _owner = "";

    public async Task LoadAsync(IApiClient api, string account)
    {
        if (_owner != account) { Items = []; Status = LoadStatus.Idle; _owner = account; Changed?.Invoke(); }
        if (account.Length == 0) return;
        if (Items.Count == 0) { Status = LoadStatus.Loading; Changed?.Invoke(); }
        try
        {
            var result = await api.CareerRequestAsync("/api/agent/sessions");
            if (_owner != account) return;
            Items = Sorted(result.Items("sessions").Where(x => x.Text("status") != "archived"));
            Status = LoadStatus.Ready;
        }
        catch
        {
            if (_owner != account) return;
            if (Items.Count == 0) Status = LoadStatus.Error;
        }
        Changed?.Invoke();
    }

    /// <summary>与 Web `sortSessions` 相同：置顶优先，其余按最近消息时间（没有则更新时间）倒序，ISO 字符串按序比较。</summary>
    public static List<JsonNode> Sorted(IEnumerable<JsonNode> items) => items
        .OrderByDescending(x => x.Bool("pinned") ? 1 : 0)
        .ThenByDescending(x => x.Text("last_message_at") is { Length: > 0 } last ? last : x.Text("updated_at"), StringComparer.Ordinal)
        .ToList();

    public async Task SetPinnedAsync(IApiClient api, string id, bool pinned)
    {
        var result = await api.CareerRequestAsync($"/api/agent/sessions/{id}", "PATCH", body: new JsonObject { ["pinned"] = pinned });
        Replace(result.Get("session") ?? result);
    }

    public async Task RenameAsync(IApiClient api, string id, string title)
    {
        var result = await api.CareerRequestAsync($"/api/agent/sessions/{id}", "PATCH", body: new JsonObject { ["title"] = title });
        Replace(result.Get("session") ?? result);
    }

    public async Task DeleteAsync(IApiClient api, string id)
    {
        await api.CareerRequestAsync($"/api/agent/sessions/{id}", "DELETE");
        Remove(id);
    }

    void Replace(JsonNode session)
    {
        var id = session.Text("id");
        if (id.Length == 0) return;
        Items = Sorted(new[] { session.DeepClone() }.Concat(Items.Where(x => x.Text("id") != id)));
        Changed?.Invoke();
    }

    public void Remove(string id)
    {
        Items.RemoveAll(x => x.Text("id") == id);
        Changed?.Invoke();
    }
}

/// <summary>公告中心，对应 Mac `AnnouncementCenter`：列表、未读数、60 秒内复用、全部已读、自动打开重要公告。</summary>
public sealed class AnnouncementCenter
{
    public enum LoadStatus { Idle, Loading, Ready, Error }

    public IReadOnlyList<Announcement> Items { get; private set; } = [];
    public int UnreadCount { get; private set; }
    public LoadStatus Status { get; private set; } = LoadStatus.Idle;
    public HashSet<string> FreshIds { get; private set; } = [];
    /// <summary>正在看的详情：要翻的公告 id 与当前位置。</summary>
    public (List<string> Ids, int Index)? Detail { get; set; }
    public event Action? Changed;
    DateTimeOffset _fetchedAt = DateTimeOffset.MinValue;
    string _owner = "";

    public void Reset(string account)
    {
        if (_owner == account) return;
        _owner = account; Items = []; UnreadCount = 0; Status = LoadStatus.Idle; FreshIds = []; Detail = null; _fetchedAt = DateTimeOffset.MinValue;
        Changed?.Invoke();
    }

    /// <summary>60 秒内的再次刷新复用上次结果（Web `REFRESH_INTERVAL_MS`）。</summary>
    public async Task RefreshAsync(IApiClient api, bool force = false)
    {
        if (_owner.Length == 0) return;
        if (!force && Status == LoadStatus.Ready && DateTimeOffset.Now - _fetchedAt < TimeSpan.FromSeconds(60)) return;
        var account = _owner;
        Status = LoadStatus.Loading;
        Changed?.Invoke();
        try
        {
            var list = AnnouncementList.From(await api.CareerRequestAsync("/api/announcements"));
            if (account != _owner) return;
            Items = list.Items; UnreadCount = list.UnreadCount; Status = LoadStatus.Ready;
        }
        catch
        {
            if (account != _owner) return;
            Status = LoadStatus.Error;
        }
        _fetchedAt = DateTimeOffset.Now;
        Changed?.Invoke();
    }

    public void MarkAllRead(IApiClient api)
    {
        if (UnreadCount <= 0) return;
        UnreadCount = 0;
        Items = Items.Select(x => x with { Read = true }).ToList();
        _ = api.CareerRequestAsync("/api/announcements/read-all", "POST").ContinueWith(_ => { }, TaskScheduler.Default);
        Changed?.Invoke();
    }

    public void ViewList(IApiClient api)
    {
        FreshIds = Items.Where(x => !x.Read).Select(x => x.Id).ToHashSet();
        MarkAllRead(api);
    }

    /// <summary>有未读的重要公告时自动打开详情，从重要的开始（接口已把重要排在前面），可往后翻其余未读。</summary>
    public void AutoOpenImportant(IApiClient api)
    {
        var unread = Items.Where(x => !x.Read).ToList();
        if (Detail is not null || !unread.Any(x => x.Important)) return;
        Detail = (unread.Select(x => x.Id).ToList(), 0);
        MarkAllRead(api);
    }
}
