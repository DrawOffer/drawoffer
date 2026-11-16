using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>
/// 会员与积分（Windows 稿 01 页「06 · 会员与积分弹窗」）：720 宽、四个标签同高的 ContentDialog。
/// 06.01 会员方案 / 06.04 积分充值（后端 `GET /api/agent/cards/plans` 的分组即标签）、06.05 积分明细、06.09 邀请好友。
/// 付款在浏览器的支付宝页面完成，这里轮询票据直到有结果。
/// </summary>
public static class PlansDialog
{
    /// <param name="tab">打开时停在哪个标签：后端分组 id（membership / pack）或 "credits" / "invite"；null 为第一个分组。</param>
    public static void Show(FrameworkElement owner, string? tab = null)
    {
        var view = new PlansView(tab);
        V3Overlay.Show(owner.XamlRoot, close => { view.Close = close; return V3Dialog.Frame(view, 720); }, dismissed: view.Dispose);
    }

    internal static Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null, Dictionary<string, string>? query = null, CancellationToken ct = default) =>
        App.Session.Api.CareerRequestAsync(path, method, query, body, ct);

    /// <summary>计费插画（手绘墨线 + 暖色）：tea / chicken / hotpot / sweet / coffee / film / coin-jar / paper-plane / red-envelope。</summary>
    internal static FrameworkElement Art(string name, double size) => name.Length == 0
        ? new Border { Width = size, Height = size }
        : new Image { Width = size, Height = size, Stretch = Stretch.Uniform, Source = new BitmapImage(new Uri($"ms-appx:///Assets/Branding/Billing/{name}.webp")) };

    internal static TextBlock Strike(string text, double size, Color color)
    {
        var block = Sans(text, size, color);
        block.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
        return block;
    }

    internal static double Number(JsonNode? value) =>
        value.Number() ?? (double.TryParse(value.String(), NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : 0);
}

internal sealed class PlansView : Grid, IDisposable
{
    static readonly Color Muted = Hex(0x8F8F89), Warm = Hex(0x8A5E36), Off = Hex(0xC0532B);
    readonly CancellationTokenSource _life = new();
    readonly ContentControl _tabs = new(), _body = new(), _commands = new();
    readonly Border _commandSpace;
    JsonNode? _card, _ticket, _invite;
    string _status = "loading", _group = "", _extra = "", _busy = "", _error = "", _ticketId = "", _openUrl = "", _inviteError = "";
    bool _checking, _disposed;
    readonly Dictionary<string, string> _picks = [];
    string _inviteText = "";
    CancellationTokenSource? _poll;
    public Action Close = () => { };

    public PlansView(string? tab)
    {
        if (tab is "credits" or "invite") _extra = tab; else _group = tab ?? "";
        Height = 640;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _tabs.HorizontalContentAlignment = _body.HorizontalContentAlignment = _commands.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _body.VerticalContentAlignment = VerticalAlignment.Stretch;
        var tabs = new Border { Child = _tabs, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(24, 14, 24, 0) };
        SetRow(tabs, 1);
        var body = new Border { Child = _body, Padding = new Thickness(24, 16, 24, 20) };
        SetRow(body, 2);
        _commandSpace = new Border { Child = _commands, Background = Brush(Stage), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(24, 16, 24, 16) };
        SetRow(_commandSpace, 3);
        Children.Add(new ContentControl()); // 占位，Render 时换成页头
        Children.Add(tabs);
        Children.Add(body);
        Children.Add(_commandSpace);
        Loaded += async (_, _) => await LoadAsync();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _poll?.Cancel();
        _life.Cancel();
    }

    List<JsonNode> Groups => _card.Items("groups");
    JsonNode? ActiveGroup => Groups.FirstOrDefault(x => x.Text("id") == _group) ?? Groups.FirstOrDefault();
    List<JsonNode> Items => _card.Items("items").Where(x => Groups.Count <= 1 || x.Text("group") == ActiveGroup.Text("id")).ToList();
    List<JsonNode> Buyable => Items.Where(x => x["action"] is JsonObject).ToList();
    string PickKey => ActiveGroup?.Text("id") ?? "__items";
    JsonNode? Selected => Buyable.FirstOrDefault(x => _picks.TryGetValue(PickKey, out var id) && x.Text("id") == id)
        ?? Buyable.FirstOrDefault(x => x.Bool("featured")) ?? Buyable.FirstOrDefault();
    string Phase => _ticketId.Length == 0 ? "idle" : _ticket is null || _ticket.Text("state") == "pending" ? "waiting" : _ticket.Text("state");
    bool Locked => _ticketId.Length > 0 && Phase == "waiting";

    async Task LoadAsync()
    {
        _status = "loading"; Render();
        try
        {
            var next = (await PlansDialog.Request("/api/agent/cards/plans", ct: _life.Token))["card"];
            _card = next is JsonObject ? next : null;
            _status = _card is null ? "empty" : "ready";
        }
        catch (Exception error)
        {
            if (_disposed) return;
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _status = "error";
        }
        if (!_disposed) Render();
    }

    // MARK: 渲染

    void Render()
    {
        // 页头：20/700 标题，右侧「当前：免费版」14/500
        var head = Spread(Label(_card.Text("title") is { Length: > 0 } title ? title : "会员与积分", 20, Txt, Bold),
            _card is null ? new Border() : (UIElement)Sans(_card.Text("status"), 14, Txt, Medium), 24).Pad(24, 24, 24, 0);
        SetRow(head, 0);
        Children[0] = head;
        if (_card is null)
        {
            _tabs.Content = null;
            _body.Content = _status == "loading"
                ? new V3Loading("正在加载方案…", () => _ = LoadAsync())
                : VStack(12, Sans(_status == "error" ? "暂时无法读取方案，请重试。" : "暂无可用方案", 14, Sub), new V3Button("重试", () => _ = LoadAsync())).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            _commands.Content = CloseOnly();
            return;
        }
        _tabs.Content = Tabs();
        if (_extra == "credits") { _body.Content = new CreditsPanel(); _commands.Content = CloseOnly(); }
        else if (_extra == "invite") { _body.Content = new InvitePanel(); _commands.Content = CloseOnly(); }
        else { _body.Content = Plans(); _commands.Content = Checkout(); }
    }

    UIElement CloseOnly() => HStack(8, new V3Button("关闭", Close, width: 100)).Align(HorizontalAlignment.Right);

    /// <summary>标签（Pivot 观感）：14 号、间距 24，选中墨黑 600 + 底部 3px 墨黑短条；积分明细 / 邀请好友时右侧放「会员与积分说明 ↗」。</summary>
    UIElement Tabs()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24 };
        var groups = Groups.Count == 0 ? new List<(string, string)> { ("__items", "方案") } : Groups.Select(x => (x.Text("id"), x.Text("label"))).ToList();
        foreach (var (id, label) in groups)
        {
            var key = id;
            row.Children.Add(Tab(label, _extra.Length == 0 && (key == ActiveGroup?.Text("id") || key == "__items"), () => { _group = key; _extra = ""; Render(); }));
        }
        row.Children.Add(Tab("积分明细", _extra == "credits", () => { _extra = "credits"; Render(); }));
        row.Children.Add(Tab("邀请好友", _extra == "invite", () => { _extra = "invite"; Render(); }));
        return _extra.Length > 0 ? Spread(row, ExplainLink(), 12) : row;
    }

    static UIElement Tab(string title, bool active, Action action)
    {
        var bar = new Border { Height = 3, Width = 20, CornerRadius = new CornerRadius(1.5), Background = Brush(active ? Txt : Clear), HorizontalAlignment = HorizontalAlignment.Left };
        var label = Label(title, 14, active ? Txt : Sub, active ? Semibold : Regular);
        return VStack(8, label, bar).Pad(0, 0, 0, 0).OnTap(action, title);
    }

    static UIElement ExplainLink() => Sans("会员与积分说明 ↗", 12, Sub).OnTap(() => WebBridge.Open("/pricing/credits"), "会员与积分说明");

    UIElement Plans()
    {
        var notes = ActiveGroup?["notes"].Items().Select(x => x.String() ?? "").Where(x => x.Length > 0).ToList() ?? [];
        var info = HStack(6, _card.Text("text").Length > 0 ? Sans(_card.Text("text"), 12, Sub) : null,
            notes.Count > 0 ? Icon("questionmark.circle", 12, Sub).Tip(string.Join("\n", notes)) : null);
        var cards = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 16, 0, 0) };
        var items = Items;
        for (var i = 0; i < items.Count; i++)
        {
            cards.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var card = PlanCard(items[i]);
            SetColumn(card, i);
            cards.Children.Add(card);
        }
        var stack = VStack(0, Spread(info, ExplainLink(), 12), cards);
        if (_error.Length > 0) stack.Children.Add(Sans(_error, 13, Red).Top(10));
        return Scroll(stack);
    }

    /// <summary>方案卡：圆角 8、Cl 描边（选中 1.5 墨黑），内边距 16；方案名 18/600 + 描边小徽标 → 副标题 → 价格 32 + 周期 → 划线原价 + 「限时 N 折」→ 48 插画与「≈ 多少钱」→ 细线 → 积分 → 权益。</summary>
    Border PlanCard(JsonNode item)
    {
        var selectable = item["action"] is JsonObject;
        var on = selectable && item.Text("id") == Selected?.Text("id");
        var dimmed = (Locked || _busy.Length > 0) && !on;
        var stack = new StackPanel();
        var badge = item.Text("badge").Length == 0 ? null : new Border
        {
            Height = 18, Padding = new Thickness(6, 0, 6, 0), CornerRadius = new CornerRadius(3), BorderBrush = Brush(Hex(0xD6D6D1)), BorderThickness = new Thickness(1),
            Child = Sans(item.Text("badge"), 11, Muted).Align(v: VerticalAlignment.Center),
        };
        stack.Children.Add(HStack(8, Label(item.Text("title"), 18, Txt, Semibold), badge));
        stack.Children.Add(Sans(item.Text("subline") is { Length: > 0 } sub ? sub : " ", 12, Muted).Top(4));
        if (item.Text("price").Length > 0)
        {
            var price = HStack(4, Label(item.Text("price"), 32, Txt, Semibold), item.Text("period").Length > 0 ? Sans(item.Text("period"), 12, Muted).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 6) : null);
            stack.Children.Add(price.Top(18));
            stack.Children.Add(HStack(8, item.Text("original").Length > 0 ? PlansDialog.Strike(item.Text("original"), 12, Hex(0xB0B0AA)) : null,
                item.Text("offTag").Length > 0 ? Sans(item.Text("offTag"), 12, Off) : null).Frame(height: 16).Top(2));
            stack.Children.Add(item["analogy"] is JsonObject analogy
                ? (UIElement)HStack(10, PlansDialog.Art(analogy.Text("icon"), 48), Sans(analogy.Text("text"), 13, Warm, Medium).Align(v: VerticalAlignment.Center)).Top(12)
                : new Border { Height = 60 });
        }
        stack.Children.Add(new Border { Height = 1, Background = Brush(Hex(0xF0F0EC)), Margin = new Thickness(0, 12, 0, 0) });
        if (item.Text("headline").Length > 0) stack.Children.Add(Label(item.Text("headline"), 14, Txt, Medium).Top(16));
        var lines = VStack(8);
        foreach (var line in item["lines"].Items().Select(x => x.String() ?? ""))
            lines.Children.Add(Columns(8, (Auto, Icon("checkmark", 10, Hex(0xA8A8A2)).Pad(0, 3, 0, 0).Align(v: VerticalAlignment.Top)), (Star(), Sans(line, 12, Hex(0x4A4A46)).Wrap())));
        stack.Children.Add(lines.Top(10));
        if (item.Text("note").Length > 0) stack.Children.Add(Sans(item.Text("note"), 12, Fnt).Wrap().Top(10));
        var card = new Border
        {
            Child = stack, Padding = new Thickness(16), CornerRadius = new CornerRadius(8), Background = Brush(White),
            BorderBrush = Brush(on ? Txt : Cl), BorderThickness = new Thickness(on ? 1.5 : 1),
            Opacity = dimmed ? 0.55 : selectable ? 1 : 0.7,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, item.Text("title"));
        if (selectable) card.OnTap(() =>
        {
            if (Locked || _busy.Length > 0) return;
            _picks[PickKey] = item.Text("id");
            Render();
        }, item.Text("title"));
        return card;
    }

    /// <summary>CommandSpace 结算行：左侧邀请码 / 付款进度，右侧「应付 ~~原价~~ 现价」与说明，最右唯一的墨黑胶囊。</summary>
    UIElement Checkout()
    {
        if (Selected is not { } selected || selected["action"] is not JsonObject action) return CloseOnly();
        var phase = Phase;
        var inviteConfig = _card?["invite"] is JsonObject invite && Buyable.Any(x => x.Text("group") == invite.Text("group")) ? invite : null;
        var priced = _invite?["prices"]?[action.Text("id")];
        var original = phase == "idle" ? (priced.Text("original") is { Length: > 0 } o ? o : action.Text("amount") == selected.Text("price") && selected.Text("original").Length > 0 ? selected.Text("original") : null) : null;

        UIElement left = phase != "idle" ? PayStatus()
            : inviteConfig is null ? new Border()
            : selected.Text("group") == inviteConfig.Text("group") ? Coupon(inviteConfig)
            : Sans("积分包长期有效，不使用邀请码", 12, Fnt).Align(v: VerticalAlignment.Center);

        UIElement? amount = null;
        if (phase is "idle" or "waiting" or "closed")
        {
            var price = (phase == "idle" ? priced.Text("price") : "") is { Length: > 0 } p ? p : action.Text("amount") is { Length: > 0 } a ? a : selected.Text("price");
            var line = HStack(8, Sans("应付", 13, Sub).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 4),
                original is null ? null : PlansDialog.Strike(original, 13, Hex(0xB0B0AA)).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 4),
                Label(price, 24, Txt, Semibold));
            line.HorizontalAlignment = HorizontalAlignment.Right;
            amount = VStack(0, line, action.Text("caption").Length > 0 ? Sans(action.Text("caption"), 11, Hex(0x9A9A94)).Align(HorizontalAlignment.Right) : null);
        }

        V3Button button = phase switch
        {
            "waiting" => new V3Button("等待付款结果", () => { }, V3Button.Kind.Dark) { Enabled = false },
            "done" => new V3Button("知道了", () => _ = FinishAsync(), V3Button.Kind.Dark),
            "review" or "refunded" => new V3Button("知道了", () => _ = FinishAsync()),
            _ => new V3Button(_busy == action.Text("id") ? "正在处理…" : action.Text("label"), () => _ = RunAsync(action.Text("id")), V3Button.Kind.Dark) { Enabled = _busy.Length == 0 },
        };
        button.MinWidth = 100;
        return Columns(16, (Star(), left), (Auto, amount ?? new Border()), (Auto, button.Align(v: VerticalAlignment.Center)));
    }

    /// <summary>邀请码：260×32 的白底输入框（圆角 4、Cl 描边），链接图标 + 「填好友邀请码，立减 ¥5」+ 文字按钮「使用」；核对成功后变成已减提示。</summary>
    UIElement Coupon(JsonNode config)
    {
        if (_invite is { } invite)
            return new Border
            {
                Width = 260, Height = 32, CornerRadius = new CornerRadius(4), Background = Brush(Hex(0xF6F3EC)), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Padding = new Thickness(10, 0, 8, 0),
                Child = Columns(8, (Auto, Icon("ticket", 12, Fnt).Align(v: VerticalAlignment.Center)),
                    (Auto, Label(invite.Text("code"), 13, Txt, Medium).Align(v: VerticalAlignment.Center)),
                    (Star(), Sans($"已减 {invite.Text("discount")}", 12, Off, Medium).Align(v: VerticalAlignment.Center)),
                    (Auto, Sans("移除", 12, Fnt).Align(v: VerticalAlignment.Center).OnTap(() => { if (_busy.Length > 0) return; _invite = null; _inviteText = _inviteError = ""; Render(); }, "移除邀请码"))),
            }.Align(HorizontalAlignment.Left, VerticalAlignment.Center);
        var box = new TextBox
        {
            Text = _inviteText, MaxLength = 32, FontSize = 13, BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0, 5, 0, 0),
            PlaceholderText = config.Text("label") + (config.Text("entry").Length > 0 ? "，" + config.Text("entry") : ""), PlaceholderForeground = Brush(Muted),
            CharacterCasing = CharacterCasing.Upper, VerticalAlignment = VerticalAlignment.Center,
        };
        Quiet(box.Resources);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, config.Text("label"));
        var use = Label(_checking ? "核对中…" : "使用", 12, Txt, Medium).Align(v: VerticalAlignment.Center);
        use.Opacity = _checking || _inviteText.Trim().Length == 0 ? 0.45 : 1;
        box.TextChanged += (_, _) => { _inviteText = box.Text; _inviteError = ""; use.Opacity = _inviteText.Trim().Length == 0 ? 0.45 : 1; };
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _ = CheckInviteAsync(); } };
        var field = new Border
        {
            Width = 260, Height = 32, CornerRadius = new CornerRadius(4), Background = Brush(White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Padding = new Thickness(10, 0, 10, 0),
            Child = Columns(8, (Auto, Icon("link", 12, Muted).Align(v: VerticalAlignment.Center)), (Star(), box), (Auto, use.OnTap(() => _ = CheckInviteAsync(), "使用邀请码"))),
        };
        return VStack(4, field, _inviteError.Length > 0 ? Sans(_inviteError, 12, Red) : null).Align(HorizontalAlignment.Left, VerticalAlignment.Center);
    }

    /// <summary>付款进度：等待中可重新打开支付宝页；结束后显示后端给的结果文字。</summary>
    UIElement PayStatus()
    {
        var phase = Phase;
        var tone = phase == "waiting" ? "wait" : phase == "done" ? "ok" : phase == "closed" ? "info" : "warn";
        var (back, fore) = tone switch
        {
            "ok" => (GreenSoft, Hex(0x2F7D4F)),
            "info" => (Field, Sub),
            "warn" => (OrangeSoft, Hex(0xC9781A)),
            _ => (Field, Txt),
        };
        var icon = new Border
        {
            Width = 32, Height = 32, CornerRadius = new CornerRadius(16), Background = Brush(back),
            Child = Icon(tone switch { "wait" => "arrow.triangle.2.circlepath", "ok" => "checkmark", "info" => "info.circle", _ => "exclamationmark.circle" }, 14, fore).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        var text = VStack(2, Label(phase == "waiting" ? "请在新打开的支付宝页面完成付款" : _ticket.Text("text"), 13, Txt, Medium),
            phase == "waiting" ? HStack(10, Sans("订单 15 分钟内有效，付款后这里会自动更新", 12, Sub), Sans("重新打开", 12, Link, Medium).OnTap(() => Open(_openUrl), "重新打开付款页")) : null);
        return HStack(10, icon, text.Align(v: VerticalAlignment.Center));
    }

    // MARK: 动作

    static void Open(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http") _ = Windows.System.Launcher.LaunchUriAsync(uri);
    }

    async Task CheckInviteAsync()
    {
        var code = _inviteText.Trim();
        if (code.Length == 0 || _checking) return;
        _inviteError = ""; _checking = true; Render();
        try { _invite = await PlansDialog.Request("/api/billing/invite-codes/check", "POST", new JsonObject { ["code"] = code }, ct: _life.Token); }
        catch { _invite = null; _inviteError = "邀请码不可用，请检查后重试。"; }
        _checking = false;
        if (!_disposed) Render();
    }

    /// <summary>下单后在默认浏览器打开支付宝付款页，然后轮询票据。</summary>
    async Task RunAsync(string actionId)
    {
        if (_busy.Length > 0) return;
        _error = ""; _busy = actionId; Render();
        try
        {
            var body = new JsonObject { ["idempotency_key"] = Guid.NewGuid().ToString("N") };
            if (_invite?["prices"]?[actionId] is not null) body["invite_code"] = _invite.Text("code");
            var result = await PlansDialog.Request($"/api/agent/actions/{Uri.EscapeDataString(actionId)}", "POST", body, ct: _life.Token);
            _openUrl = result.Text("open_url");
            Open(_openUrl);
            _ticket = null;
            _ticketId = result.Text("ticket");
            _ = PollAsync();
        }
        catch (Exception error) when (!_disposed)
        {
            _error = ErrorText.Is(error, "INSUFFICIENT_CREDITS") ? ErrorText.From(error, "") : "暂时无法处理，请稍后再试。";
        }
        catch { return; }
        _busy = "";
        if (!_disposed) Render();
    }

    async Task PollAsync()
    {
        _poll?.Cancel();
        var poll = CancellationTokenSource.CreateLinkedTokenSource(_life.Token);
        _poll = poll;
        var id = _ticketId;
        if (id.Length == 0) return;
        var started = DateTime.UtcNow;
        try
        {
            while (!poll.IsCancellationRequested && DateTime.UtcNow - started < TimeSpan.FromMinutes(30))
            {
                try
                {
                    var next = await PlansDialog.Request($"/api/agent/tickets/{Uri.EscapeDataString(id)}", ct: poll.Token);
                    if (id != _ticketId) return;
                    _ticket = next;
                    Render();
                    if (next.Text("state") != "pending") return;
                }
                catch (OperationCanceledException) { return; }
                catch { }
                await Task.Delay(TimeSpan.FromSeconds(3), poll.Token);
            }
        }
        catch (OperationCanceledException) { }
    }

    async Task FinishAsync()
    {
        var done = Phase == "done";
        _poll?.Cancel();
        _ticketId = ""; _ticket = null; _openUrl = "";
        Render();
        if (!done) return;
        try { if ((await PlansDialog.Request("/api/agent/cards/plans", ct: _life.Token))["card"] is JsonObject next) { _card = next; Render(); } } catch { }
    }
}
