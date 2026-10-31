using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Windows.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 即将进行的面试的准备清单（Mac `CareerPrepChecklist`，Web `PrepChecklistCard.tsx`）：每场待进行的面试可 AI 生成一次，
/// 勾选、添加与删除事项；保存时带最新的 lock_version，失败回滚并刷新。
/// </summary>
public sealed class CareerPrepChecklist : UserControl
{
    const int MaxItems = 12, MaxTitle = 80;
    static readonly Dictionary<string, string> Categories = new()
    {
        ["intro"] = "自我介绍", ["project"] = "项目深挖", ["technical"] = "技术知识", ["system_design"] = "系统设计",
        ["behavior"] = "行为与动机", ["company"] = "公司调研", ["other"] = "其他",
    };

    JsonNode _session;
    bool _readOnly;
    readonly Action _changed;
    readonly Action<string> _notice;
    string? _busy;
    List<JsonNode>? _local;
    readonly TextBox _draft = new()
    {
        PlaceholderText = "添加一项准备事项", FontSize = 13, FontFamily = SansFamily, MinHeight = 0, Height = 30, Padding = new Thickness(8, 5, 8, 0),
        CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), BorderBrush = Brush(CareerPalette.Control), Background = Brush(V3.White),
    };

    public string SessionId => _session.Text("id");

    public CareerPrepChecklist(JsonNode session, bool readOnly, Action changed, Action<string> notice)
    {
        _session = session;
        _readOnly = readOnly;
        _changed = changed;
        _notice = notice;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_draft, "添加一项准备事项");
        _draft.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Add(); } };
        _draft.TextChanged += (_, _) => Render();
        Render();
    }

    /// <summary>页面刷新后换上新的会话；lock_version 变了就丢掉本地乐观副本（`.onChange(of: lock_version)`）。</summary>
    public void Update(JsonNode session, bool readOnly)
    {
        if (session.Get("lock_version")?.ToJsonString() != _session.Get("lock_version")?.ToJsonString()) _local = null;
        _session = session;
        _readOnly = readOnly;
        Render();
    }

    List<JsonNode> Items => _local ?? _session.Items("prep_items");
    bool Generated => _session.Get("prep_generated_at") is JsonNode value && value.GetValueKind() != System.Text.Json.JsonValueKind.Null;
    bool CanGenerate => !_readOnly && _session.Text("status") == "scheduled" && !Generated;

    void Render() => KeepFocus(XamlRoot, Rebuild);

    void Rebuild()
    {
        var items = Items;
        var card = new StackPanel { Spacing = 12 };
        card.Children.Add(HStack(8, Sans("面试准备清单", 15, CareerPalette.Text, Medium),
            items.Count > 0 ? CareerChipView.Make($"{items.Count(x => x.Bool("done"))} / {items.Count} 已完成", CareerTone.Gray) : null));
        if (_busy == "generate") card.Children.Add(Sans("AI 正在根据岗位、简历和历史复盘生成清单…", 12, CareerPalette.Sub).Wrap());
        else if (items.Count == 0)
            card.Children.Add(Sans(_readOnly ? "暂无准备事项。" : CanGenerate ? "还没有准备清单。让 AI 按这场面试的岗位和简历生成一份，每场面试只能生成一次。"
                : Generated ? "清单已清空。" : "这场面试已经结束，不再生成准备清单。", 12, CareerPalette.Hint).Wrap());
        for (var index = 0; index < items.Count; index++)
        {
            var position = index;
            var item = items[index];
            var done = item.Bool("done");
            var title = Sans(item.Text("title"), 13, CareerPalette.Text, Medium).Wrap();
            if (done) title.TextDecorations = TextDecorations.Strikethrough;
            var meta = Sans(string.Join(" · ", new[] { Categories.GetValueOrDefault(item.Text("category"), "其他"), item.Text("reason") }.Where(x => x.Length > 0)), 12, CareerPalette.Sub).Wrap();
            var check = Icon(done ? "checkmark.circle.fill" : "circle", 14, done ? CareerPalette.Green : CareerPalette.Faint);
            check.VerticalAlignment = VerticalAlignment.Top;
            check.Margin = new Thickness(0, 2, 0, 0);
            var label = Columns(10, (Auto, check), (Star(), VStack(2, title, meta)));
            var toggle = Tappable(label, () => _ = ToggleAsync(position), item.Text("title"), () => !_readOnly && _busy is null);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(toggle, done ? "已完成" : "未完成");
            UIElement row = toggle;
            if (!_readOnly)
            {
                var trash = Tappable(Icon("trash", 11, CareerPalette.Faint), () => _ = SaveAsync(Items.Where((_, i) => i != position).ToList()), $"删除 {item.Text("title")}", () => _busy is null);
                trash.VerticalAlignment = VerticalAlignment.Top;
                trash.Opacity = _busy is null ? 1 : 0.5;
                row = Columns(10, (Star(), toggle), (Auto, trash));
            }
            card.Children.Add(row);
        }
        if (CanGenerate)
            card.Children.Add(new CareerAction(_busy == "generate" ? "生成中…" : "AI 生成准备清单", () => _ = GenerateAsync(), icon: "wand.and.stars") { Enabled = _busy is null });
        if (!_readOnly)
        {
            var add = new CareerAction("添加", Add) { Enabled = _busy is null && _draft.Text.Trim().Length > 0 && items.Count < MaxItems };
            card.Children.Add(Columns(8, (Star(), Detach(_draft)), (Auto, add)));
        }
        Content = card.CareerCard(20);
    }

    async Task ToggleAsync(int index)
    {
        if (Items[index] is not JsonObject fields) return;
        var next = Items.Select(x => x.DeepClone()).ToList();
        next[index]["done"] = !fields.Bool("done");
        await SaveAsync(next);
    }

    void Add()
    {
        var title = Prefix(_draft.Text.Trim(), MaxTitle);
        if (title.Length == 0 || Items.Count >= MaxItems || _busy is not null) return;
        _draft.Text = "";
        var next = Items.Select(x => x.DeepClone()).ToList();
        next.Add(new JsonObject { ["title"] = title, ["category"] = "other", ["reason"] = null, ["done"] = false });
        _ = SaveAsync(next);
    }

    async Task SaveAsync(List<JsonNode> next)
    {
        var previous = _local;
        _local = next; _busy = "save"; Render();
        try
        {
            var array = new JsonArray(next.Select(x => x.DeepClone()).ToArray());
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}", "PUT", body: new JsonObject { ["prep_items"] = array, ["base_lock_version"] = Lock(_session) });
            _busy = null; Render();
            _changed();
        }
        catch (Exception error) { Fail(error); _local = previous; _busy = null; Render(); _notice(CareerErrors.Message(error)); _changed(); }
    }

    async Task GenerateAsync()
    {
        _busy = "generate"; Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}/prep-items:generate", "POST");
            _local = null; _busy = null; Render(); _changed();
        }
        catch (Exception error)
        {
            Fail(error);
            _busy = null; Render();
            var messages = new Dictionary<string, string>
            {
                ["INTERVIEW_PREP_ALREADY_GENERATED"] = "这场面试已经生成过准备清单。", ["LLM_MODEL_NOT_CONFIGURED"] = "AI 生成暂不可用，请稍后再试。",
                ["LLM_RESPONSE_INVALID"] = "AI 这次没有生成有效的清单，可以再试一次。", ["INTERVIEW_INVALID_TRANSITION"] = "只有待进行的面试可以生成准备清单。",
            };
            if (Server(error, out var status, out var code) && (messages.GetValueOrDefault(code) ?? (status >= 500 ? "AI 暂时没能生成清单，请稍后重试。" : null)) is { } message)
            {
                _notice(message);
                if (code == "INTERVIEW_PREP_ALREADY_GENERATED") _changed();
            }
            else _notice(CareerErrors.Message(error));
        }
    }
}
