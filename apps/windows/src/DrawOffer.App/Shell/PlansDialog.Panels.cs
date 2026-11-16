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

/// <summary>06.05 积分明细：可用积分大数字 + 4px 进度条（≥80% 转橙），下方积分变动（全部 / 使用 / 获得），收入墨绿。</summary>
internal sealed class CreditsPanel : UserControl
{
    static readonly Color Warn = Hex(0xD47C28), Income = Hex(0x2F7D4F), StampColor = Hex(0x9A9A94);
    readonly StackPanel _rows = new();
    readonly Grid _root = new();
    JsonNode? _summary, _month;
    List<JsonNode>? _items;
    string _direction = "all";
    string? _cursor;
    bool _failed, _loadingMore;

    public CreditsPanel()
    {
        Content = _root;
        Loaded += async (_, _) => await LoadAsync();
    }

    static string Credits(string value) => BillingSummary.Credits(value);
    static string Credits(double value) => BillingSummary.Credits(value.ToString(CultureInfo.InvariantCulture));

    Task<JsonNode> Page(string? cursor)
    {
        var query = new Dictionary<string, string> { ["limit"] = "20" };
        if (cursor is not null) query["cursor"] = cursor;
        if (_direction != "all") query["direction"] = _direction;
        return PlansDialog.Request("/api/billing/ledger", query: query);
    }

    async Task LoadAsync()
    {
        _items = null; _failed = false; Render();
        try
        {
            var summary = PlansDialog.Request("/api/billing/summary");
            var page = Page(null);
            await Task.WhenAll(summary, page);
            _summary = summary.Result;
            _items = page.Result.Items("items");
            _cursor = page.Result.Text("nextCursor") is { Length: > 0 } next ? next : null;
            if (page.Result["month"] is JsonObject month) _month = month;
        }
        catch { _failed = true; }
        Render();
    }

    async Task MoreAsync()
    {
        if (_cursor is null || _loadingMore) return;
        _loadingMore = true; Render();
        try
        {
            var page = await Page(_cursor);
            _items = (_items ?? []).Concat(page.Items("items")).ToList();
            _cursor = page.Text("nextCursor") is { Length: > 0 } next ? next : null;
        }
        catch { }
        _loadingMore = false;
        Render();
    }

    void Render()
    {
        _root.Children.Clear();
        _root.RowDefinitions.Clear();
        if (_failed)
        {
            _root.Children.Add(VStack(12, Sans("暂时无法读取积分明细，请重试。", 14, Sub), new V3Button("重试", () => _ = LoadAsync())));
            return;
        }
        if (_summary is not { } summary) { _root.Children.Add(new V3Loading("正在加载…")); return; }
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var balances = summary["balances"];
        var member = summary.Text("tier") != "none";
        var extra = PlansDialog.Number(balances?["pack"]?["remaining"]) + PlansDialog.Number(balances?["gift"]?["remaining"]);
        var periodTotal = member ? PlansDialog.Number(balances?["membership"]?["total"] ?? balances?["membership"]?["remaining"]) : PlansDialog.Number(balances?["freeMonthly"]?["total"]);
        var periodLeft = member ? PlansDialog.Number(balances?["membership"]?["remaining"]) : PlansDialog.Number(balances?["freeMonthly"]?["remaining"]);
        var used = Math.Max(0, periodTotal - periodLeft);
        var total = periodTotal + extra;
        var share = total > 0 ? Math.Min(1, used / total) : 0;
        var percent = (int)Math.Round(share * 100);
        var warn = share >= 0.8;
        var reset = member
            ? balances?["membership"].Text("expireTime") is { Length: > 0 } expire ? $"{MonthDay(expire)}到期，未用完的清零" : ""
            : $"{MonthDay(balances?["freeMonthly"].Text("resetTime") ?? "")}重置为 {Credits(balances?["freeMonthly"].Display("total") ?? "")}";

        var bar = new Grid { Height = 4 };
        bar.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = Brush(Hex(0xEEEEEA)) });
        var fill = new Border { CornerRadius = new CornerRadius(2), Background = Brush(warn ? Warn : Txt), HorizontalAlignment = HorizontalAlignment.Left };
        bar.SizeChanged += (_, e) => fill.Width = Math.Max(4, e.NewSize.Width * share);
        bar.Children.Add(fill);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(bar, $"已用积分 {percent}%");

        var head = VStack(10,
            Spread(VStack(2, Sans(member ? "会员积分" : "本月免费积分", 13, Sub),
                    HStack(8, Label(Credits(summary.Display("available")), 36, Txt, Semibold), Sans("积分可用", 13, Sub).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 7))),
                Label($"已用 {percent}%", 13, warn ? Warn : Txt, Medium).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 4), 16, VerticalAlignment.Bottom),
            bar,
            Spread(Sans($"{(member ? "本期" : "本月")}已用 {Credits(used)} / {Credits(total)}", 12, Sub), Sans(reset, 12, Sub)),
            PlansDialog.Number(summary["overdraft"]) > 0 ? Sans($"含透支 {Credits(summary.Display("overdraft"))} 积分，下次获得积分时先抵扣", 12, Fnt)
                : !member && extra == 0 ? Sans("免费积分只能用基础模型；开通会员可用全部模型", 12, Fnt) : null);
        var headBox = new Border { Child = head, Padding = new Thickness(0, 0, 0, 18), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1) };
        _root.Children.Add(headBox);

        var filters = HStack(6);
        foreach (var (id, label) in new[] { ("all", "全部"), ("use", "使用"), ("gain", "获得") })
        {
            var key = id;
            filters.Children.Add(new V3FilterChip(label, _direction == key, () => { if (_direction == key) return; _direction = key; _ = LoadAsync(); }));
        }
        var title = Spread(HStack(16, Label("积分变动", 15, Txt, Medium).Align(v: VerticalAlignment.Center), filters),
            _month is { } month ? (UIElement)Sans($"本月使用 {Credits(month.Display("used"))} · 获得 {Credits(month.Display("gained"))}", 12, Fnt).Align(v: VerticalAlignment.Center) : new Border()).Pad(0, 14, 0, 4);
        Grid.SetRow(title, 1);
        _root.Children.Add(title);

        UIElement list;
        if (_items is null) list = Sans("正在加载…", 13, Fnt).Pad(0, 12, 0, 0);
        else if (_items.Count == 0) list = Sans("还没有积分变动。", 13, Fnt).Pad(0, 12, 0, 0);
        else
        {
            _rows.Children.Clear();
            for (var i = 0; i < _items.Count; i++) _rows.Children.Add(Row(_items[i], i == 0));
            if (_cursor is not null)
                _rows.Children.Add(Sans(_loadingMore ? "正在加载…" : "加载更早的记录", 12, Sub).Align(HorizontalAlignment.Center).Pad(0, 10, 0, 4).OnTap(() => _ = MoreAsync(), "加载更早的记录"));
            list = Scroll(_rows);
        }
        Grid.SetRow((FrameworkElement)list, 2);
        _root.Children.Add(list);
    }

    static UIElement Row(JsonNode row, bool first)
    {
        var points = PlansDialog.Number(row["points"]);
        var muted = row.Text("entryType") is "expire" or "void";
        var value = points > 0 ? "+" + Credits(row.Display("points")) : Credits(row.Display("points")).Replace("-", "−");
        var amount = Label(value, 14, muted ? Fnt : points > 0 ? Income : Txt, Semibold);
        amount.TextAlignment = TextAlignment.Right;
        return new Border
        {
            Padding = new Thickness(0, 10, 0, 10), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, first ? 0 : 1, 0, 0),
            Child = Columns(16, (Star(), Label(row.Text("title"), 14, muted ? Fnt : Txt)), (Auto, Sans(Stamp(row.Text("occurTime")), 12, StampColor).Align(v: VerticalAlignment.Center)), (new GridLength(72), amount)),
        };
    }

    static string MonthDay(string value) => DateTimeOffset.TryParse(value, out var date) ? $"{date.ToBeijing().Month} 月 {date.ToBeijing().Day} 日" : "";

    /// <summary>「今天 15:30」或「10-26 15:30」。</summary>
    static string Stamp(string value)
    {
        if (!DateTimeOffset.TryParse(value, out var date)) return "";
        var local = date.ToBeijing();
        return local.Date == Beijing.Today ? "今天 " + local.ToString("HH:mm") : local.ToString("MM-dd HH:mm");
    }
}

/// <summary>06.09 邀请好友：上排邀请券（暖纸底 + 红包插画）与返现说明并排，下面是邀请记录卡。</summary>
internal sealed class InvitePanel : UserControl
{
    static readonly Color Paper = Hex(0xFBF1E6), Ink = Hex(0x1B1B19), Gray = Hex(0x62625D), Pale = Hex(0x9A9A94), Rule = Hex(0xECECE8), Strip = Hex(0xF6F6F3);
    JsonNode? _mine;
    List<JsonNode> _records = [];
    bool _failed;
    string _copied = "";

    public InvitePanel()
    {
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    static string Yuan(string value) => "¥" + (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : 0).ToString("0.00", CultureInfo.InvariantCulture);
    static string Amount(string value) => (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : 0).ToString("0.##", CultureInfo.InvariantCulture);

    async Task LoadAsync()
    {
        try
        {
            var code = PlansDialog.Request("/api/billing/invite-code");
            var list = PlansDialog.Request("/api/billing/invite-rewards", query: new() { ["limit"] = "20" });
            await Task.WhenAll(code, list);
            _mine = code.Result; _records = list.Result.Items("items"); _failed = false;
        }
        catch { _failed = true; }
        Render();
    }

    void Render()
    {
        if (_failed) { Content = VStack(12, Sans("暂时无法读取邀请信息，请重试。", 14, Sub), new V3Button("重试", () => _ = LoadAsync())); return; }
        if (_mine is not { } mine) { Content = new V3Loading("正在加载…"); return; }
        var rewards = mine.Items("rewards");
        var root = new Grid { RowSpacing = 12 };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(Columns(12, (new GridLength(1.05, GridUnitType.Star), Coupon(mine)), (Star(), Rewards(rewards))));
        var ledger = Ledger(mine, rewards);
        Grid.SetRow(ledger, 1);
        root.Children.Add(ledger);
        Content = root;
    }

    /// <summary>邀请券：暖纸底、圆角 8；左栏红包插画 + 「立减 ¥5」，竖向虚线隔开，右栏邀请码与两个复制按钮。</summary>
    UIElement Coupon(JsonNode mine)
    {
        var left = VStack(0, PlansDialog.Art("red-envelope", 44).Align(HorizontalAlignment.Left),
            Sans("好友开通会员", 12, Hex(0x8F8F89)).Top(8),
            HStack(4, Label("立减", 13, Txt, Medium).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 6), Label("¥" + Amount(mine.Text("discountAmount")), 30, Txt, Semibold)));
        var dash = new Microsoft.UI.Xaml.Shapes.Line { Y1 = 0, Y2 = 112, Stroke = Brush(Hex(0xCFC8B8)), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 4, 3 }, VerticalAlignment = VerticalAlignment.Center };
        var code = Label(mine.Text("code"), 24, Ink, Semibold);
        code.CharacterSpacing = 80;
        var right = VStack(0, Sans("我的邀请码", 12, Gray), code.Top(4),
            HStack(8, new V3Button(_copied == "code" ? "已复制" : "复制邀请码", () => Copy("code", mine), V3Button.Kind.Dark, height: 28),
                new V3Button(_copied == "text" ? "已复制" : "复制邀请文案", () => Copy("text", mine), height: 28)).Top(20));
        return new Border
        {
            Height = 136, CornerRadius = new CornerRadius(8), Background = Brush(Paper), Padding = new Thickness(16, 12, 16, 12),
            Child = Columns(16, (Auto, left.Align(v: VerticalAlignment.Bottom)), (Auto, dash), (Star(), right.Align(v: VerticalAlignment.Center))),
        };
    }

    UIElement Rewards(List<JsonNode> rewards)
    {
        var row = new Grid();
        for (var i = 0; i < rewards.Count; i++)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var cell = VStack(2, Sans(rewards[i].Text("title"), 12, Gray), Label(rewards[i].Text("reward"), 20, Txt, Semibold), Sans($"好友付 {rewards[i].Text("price")}", 11, Pale));
            Grid.SetColumn(cell, i);
            row.Children.Add(cell);
        }
        return new Border
        {
            Height = 136, CornerRadius = new CornerRadius(8), BorderBrush = Brush(Rule), BorderThickness = new Thickness(1), Padding = new Thickness(14, 12, 14, 12),
            Child = Columns(0, (Star(), VStack(14, Label("好友每开通一次会员，你得到现金返现", 13, Ink, Medium), row, Sans("返现按好友实际付款计算，核实后用微信或支付宝转给你", 11, Pale).Wrap()))),
        };
    }

    /// <summary>邀请记录卡：标题 + 邀请码小签，右侧三项统计（为 0 时数字转灰）；「领取返现」三步走在浅灰条里；没有记录时淡出示例行 + 分享提示。</summary>
    UIElement Ledger(JsonNode mine, List<JsonNode> rewards)
    {
        static UIElement Stat(string label, string value, bool zero) => HStack(4, Sans(label, 12, Pale), Label(value, 12, zero ? Pale : Txt, Medium));
        var tag = new Border { Height = 20, Padding = new Thickness(8, 0, 8, 0), CornerRadius = new CornerRadius(4), Background = Brush(Strip), Child = Label(mine.Text("code"), 11, Gray, Medium).Align(v: VerticalAlignment.Center) };
        var invited = mine.Integer("invitedCount");
        var head = Spread(HStack(10, Label("我的邀请记录", 14, Ink, Medium).Align(v: VerticalAlignment.Center), tag),
            HStack(12, Stat("待结算", Yuan(mine.Text("pendingAmount")), PlansDialog.Number(mine["pendingAmount"]) == 0),
                Stat("已到账", Yuan(mine.Text("paidAmount")), PlansDialog.Number(mine["paidAmount"]) == 0),
                Stat("已邀请", $"{invited} 人", invited == 0)).Align(v: VerticalAlignment.Center));
        var steps = HStack(8, Label("领取返现", 12, Ink, Medium));
        string[] texts = ["截图这份记录", "添加客服微信并发送截图", "核实后用微信或支付宝转给你"];
        for (var i = 0; i < texts.Length; i++)
        {
            if (i > 0) steps.Children.Add(Sans("→", 12, Pale));
            steps.Children.Add(Sans($"{"①②③"[i]} {texts[i]}", 12, Gray));
        }
        var strip = new Border
        {
            Height = 34, CornerRadius = new CornerRadius(4), Background = Brush(Strip), Padding = new Thickness(12, 0, 4, 0),
            Child = Columns(8, (Star(), steps.Align(v: VerticalAlignment.Center)), (Auto, new V3Button("查看客服微信", SupportQr, height: 26).Align(v: VerticalAlignment.Center))),
        };
        UIElement body;
        if (_records.Count == 0)
        {
            var samples = new StackPanel { Opacity = 0.35 };
            for (var i = 0; i < Math.Min(3, rewards.Count); i++)
                samples.Children.Add(Columns(12,
                    (Auto, new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 22, Height = 22, Stroke = Brush(Hex(0xC9C9C3)), StrokeDashArray = new DoubleCollection { 3, 2 } }),
                    (Star(), Sans($"好友 {(char)('A' + i)} 开通{rewards[i].Text("title")}", 13, Hex(0x9C9C96)).Align(v: VerticalAlignment.Center)),
                    (Auto, Label("+" + rewards[i].Text("reward"), 13, Pale, Semibold).Align(v: VerticalAlignment.Center))).Pad(0, 9, 0, 9));
            var prompt = VStack(6,
                Label("还没有好友用你的邀请码开通会员", 14, Hex(0x1F1F1C), Medium).Align(HorizontalAlignment.Center),
                Sans("把邀请文案发到同学群或求职群，好友开通后返现会记在这里", 12, Hex(0x6B6B66)).Align(HorizontalAlignment.Center),
                new V3Button(_copied == "text" ? "已复制" : "复制邀请文案", () => Copy("text", mine), height: 28).Align(HorizontalAlignment.Center).Top(10));
            prompt.VerticalAlignment = VerticalAlignment.Bottom;
            body = new Grid { Children = { samples, prompt } };
        }
        else
        {
            var rows = new StackPanel();
            for (var i = 0; i < _records.Count; i++) rows.Children.Add(Record(_records[i], i == 0));
            body = Scroll(rows);
        }
        var card = new Grid { RowSpacing = 10 };
        card.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        card.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        card.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        card.Children.Add(head);
        Grid.SetRow(strip, 1); card.Children.Add(strip);
        Grid.SetRow((FrameworkElement)body, 2); card.Children.Add(body);
        return new Border { Child = card, CornerRadius = new CornerRadius(8), BorderBrush = Brush(Rule), BorderThickness = new Thickness(1), Padding = new Thickness(14, 12, 14, 12) };
    }

    static UIElement Record(JsonNode row, bool first)
    {
        var status = row.Text("status");
        var (label, back, fore) = status switch
        {
            "pending" => ("待结算", Hex(0xFBF0E2), Hex(0xB8661A)),
            "paid" => ("已到账", Hex(0xE7F3EC), Hex(0x2E7D4F)),
            _ => ("已退款", Hex(0xF1F1EE), Fnt),
        };
        var date = DateTimeOffset.TryParse(row.Text("createTime"), out var time) ? time.ToBeijing().ToString("M-dd") : "";
        var buyer = row.Text("buyerLabel");
        var amount = Label(Yuan(row.Text("amount")), 13, status == "void" ? Fnt : Txt, Medium);
        amount.TextAlignment = TextAlignment.Right;
        if (status == "void") amount.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
        return new Border
        {
            Padding = new Thickness(0, 9, 0, 9), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, first ? 0 : 1, 0, 0),
            Child = Columns(12,
                (Auto, AvatarCircle.Make(null, buyer.Length > 0 ? System.Globalization.StringInfo.GetNextTextElement(buyer) : "?", 24)),
                (Star(), Sans($"{buyer} 开通{row.Text("planTitle")}", 13, status == "void" ? Fnt : Txt).Align(v: VerticalAlignment.Center)),
                (Auto, Sans(date, 12, Fnt).Align(v: VerticalAlignment.Center)),
                (Auto, new Border { Height = 20, Padding = new Thickness(8, 0, 8, 0), CornerRadius = new CornerRadius(10), Background = Brush(back), Child = Label(label, 11, fore, Medium).Align(v: VerticalAlignment.Center) }.Align(v: VerticalAlignment.Center)),
                (new GridLength(64), amount.Align(v: VerticalAlignment.Center))),
        };
    }

    void Copy(string kind, JsonNode mine)
    {
        var origin = App.Session.Api.Origin.GetLeftPart(UriPartial.Authority);
        var text = kind == "code" ? mine.Text("code")
            : $"我在用 DrawOffer 准备求职。开通会员时填写我的邀请码 {mine.Text("code")}，立减 ¥{Amount(mine.Text("discountAmount"))}：{origin}";
        if (!Files.Copy(text)) { V3Toast.Show("无法复制，请手动记下邀请码", V3Toast.Kind.Error); return; }
        _copied = kind;
        Render();
        _ = Reset();
        async Task Reset() { await Task.Delay(1600); if (_copied == kind) { _copied = ""; Render(); } }
    }

    /// <summary>客服微信二维码：叠在额度弹窗上的一层（Esc 只关这一层）；图片是 Web 站点的公开静态文件。</summary>
    void SupportQr()
    {
        V3Overlay.Show(XamlRoot, close =>
        {
            var image = new Image { Width = 240, Height = 240, Stretch = Stretch.Uniform, Source = new BitmapImage(new Uri(App.Session.Api.Origin, "/support-wechat-qr.png")) };
            var failed = Sans("二维码暂时无法显示，请稍后再试", 12, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            failed.Visibility = Visibility.Collapsed;
            image.ImageFailed += (_, _) => { image.Visibility = Visibility.Collapsed; failed.Visibility = Visibility.Visible; };
            var frame = new Border
            {
                Width = 256, Height = 256, CornerRadius = new CornerRadius(8), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
                Child = new Grid { Children = { image, failed } }, HorizontalAlignment = HorizontalAlignment.Center,
            };
            var body = VStack(0, V3DialogHead.Make("添加客服微信", "用微信扫码添加，发送邀请记录截图；核实后用微信或支付宝把返现转给你。"), frame.Top(20));
            return V3Dialog.Make(body, [new V3Button("关闭", close)], close, width: 400);
        });
    }
}
