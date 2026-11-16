using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Account;

sealed record AccountApiKey(string Id, string Name, string Scope, string Prefix)
{
    public const int Limit = 5;
    public string ScopeLabel => Scope == "read_write" ? "读写" : "只读";

    public static AccountApiKey? From(JsonNode node) =>
        node.Text("id") is { Length: > 0 } id ? new(id, node.Text("name"), node.Text("scope"), node.Text("key_prefix")) : null;

    public static string Error(Exception error, string fallback) => ErrorText.From(error, fallback, new Dictionary<string, string>
    {
        ["API_KEY_LIMIT_REACHED"] = $"最多只能保留 {Limit} 把 Key，请先删除不用的 Key。",
        ["API_KEY_NOT_FOUND"] = "这把 Key 已经删除。",
        ["INVALID_API_KEY_NAME"] = "名称需要 1–64 个字符。",
    });
}

/// <summary>
/// 04.11 API Key：标题行（15/500「API Key」+ 右侧蓝色「＋ 创建 Key」），说明一句 +「怎么配置 →」；
/// 一把一行 50 高——名称 / 等宽前缀 / 权限 / 垃圾桶（悬停只变红，不加灰底）。最多 5 把。
/// </summary>
sealed class AccountApiKeySection : UserControl
{
    const string GuideUrl = "https://github.com/DrawOffer/drawoffer-mcp";
    readonly StackPanel _list = new();
    readonly V3Button _create;
    List<AccountApiKey> _keys = [];
    bool _loading = true, _failed;

    public AccountApiKeySection()
    {
        _create = new V3Button("创建 Key", OpenCreate, V3Button.Kind.Text, height: 28, icon: "plus") { Tint = Link };
        var head = Spread(Label("API Key", 15, Txt, Medium), _create);
        var intro = HStack(6,
            Sans($"让 Claude、Cursor 等 AI 工具通过 MCP 读取你的简历、岗位和投递记录，最多 {AccountApiKey.Limit} 把。", 12, Fnt).Wrap(),
            Sans("怎么配置 →", 12, Link).OnTap(() => _ = Windows.System.Launcher.LaunchUriAsync(new Uri(GuideUrl)), "怎么配置"));
        Content = VStack(0, head.Frame(height: 28), intro.Pad(0, 2, 0, 8), Divider(), _list);
        Loaded += async (_, _) => await LoadAsync();
    }

    async Task LoadAsync()
    {
        _loading = true; _failed = false; Render();
        try
        {
            var value = await AccountPage.Request("/api/account/api-keys");
            _keys = value.Items("items").Select(AccountApiKey.From).OfType<AccountApiKey>().ToList();
        }
        catch { _failed = true; }
        _loading = false;
        Render();
    }

    void Render()
    {
        _list.Children.Clear();
        var full = _keys.Count >= AccountApiKey.Limit;
        _create.Enabled = !_loading && !_failed && !full;
        ToolTipService.SetToolTip(_create, full ? $"最多 {AccountApiKey.Limit} 把，请先删除不用的 Key" : "创建 Key");
        if (_loading && _keys.Count == 0) { _list.Children.Add(Line(Sans("正在读取 API Key…", 13, Fnt))); return; }
        if (_failed)
        {
            _list.Children.Add(Line(HStack(8, Sans("API Key 读取失败。", 13, Sub), Sans("重试", 13, Link).OnTap(() => _ = LoadAsync(), "重试"))));
            return;
        }
        if (_keys.Count == 0) { _list.Children.Add(Line(Sans("还没有 API Key。", 13, Fnt))); return; }
        foreach (var key in _keys) _list.Children.Add(Row(key));
    }

    static Border Line(UIElement child) => new()
    {
        MinHeight = 50, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1),
        Child = child is FrameworkElement element ? element.Align(HorizontalAlignment.Left, VerticalAlignment.Center) : child,
    };

    Border Row(AccountApiKey key)
    {
        var trash = Icon("trash", 12, Fnt);
        var delete = new Border { Width = 20, Height = 20, Background = Brush(Clear), Child = trash.Align(HorizontalAlignment.Center, VerticalAlignment.Center) }
            .OnTap(() => ConfirmDelete(key), $"删除 {key.Name}").Tip("删除");
        delete.OnHover(h => trash.Foreground = Brush(h ? Red : Fnt));
        var prefix = Sans($"{key.Prefix}…", 12, Fnt);
        prefix.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        var row = Columns(16,
            (Star(), Label(key.Name, 14, Txt)),
            (Auto, prefix.Align(v: VerticalAlignment.Center)),
            (new GridLength(28), Sans(key.ScopeLabel, 13, Sub).Align(HorizontalAlignment.Right, VerticalAlignment.Center)),
            (Auto, delete));
        return Line(row.Align(HorizontalAlignment.Stretch, VerticalAlignment.Center));
    }

    async void ConfirmDelete(AccountApiKey key)
    {
        if (!await V3Dialog.ConfirmAsync(XamlRoot, $"删除「{key.Name}」？", "删除后，正在使用这把 Key 的工具会立即无法访问。", "删除", danger: true)) return;
        try { await AccountPage.Request($"/api/account/api-keys/{Uri.EscapeDataString(key.Id)}", "DELETE"); }
        catch (Exception error) when (!ErrorText.Is(error, "API_KEY_NOT_FOUND"))
        {
            V3Toast.Show(AccountApiKey.Error(error, "删除失败，请重试。"), V3Toast.Kind.Error);
            return;
        }
        _keys.RemoveAll(x => x.Id == key.Id);
        Render();
        V3Toast.Show("API Key 已删除");
    }

    /// <summary>创建（520 宽）：名称 ≤64 + 权限单选（只读推荐 / 读写），成功后换成只显示一次的 Key（560 宽）。</summary>
    void OpenCreate()
    {
        V3Overlay.Show(XamlRoot, close =>
        {
            var name = Input("", "", 64);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(name, "名称");
            var scope = "read";
            var options = new StackPanel { Spacing = 8 };
            (string id, string label, string note)[] scopes = [("read", "只读", "只能读取，推荐"), ("read_write", "读写", "还能新增岗位和投递记录")];
            void PaintOptions()
            {
                options.Children.Clear();
                foreach (var option in scopes)
                {
                    var on = option.id == scope;
                    var id = option.id;
                    options.Children.Add(HStack(8,
                        Icon(on ? "largecircle.fill.circle" : "circle", 14, on ? Txt : Fnt2),
                        Label(option.label, 13, Txt), Sans(option.note, 12, Fnt)).OnTap(() => { scope = id; PaintOptions(); }, $"{option.label}：{option.note}"));
                }
            }
            PaintOptions();
            var error = Sans("", 12, Red).Wrap(2);
            var saving = false;
            V3Button? save = null;
            async void Save()
            {
                if (saving) return;
                var trimmed = name.Text.Trim();
                if (trimmed.Length is 0 or > 64) { error.Text = "名称需要 1–64 个字符。"; return; }
                saving = true; save!.Enabled = false; save.Title = "创建中…"; error.Text = "";
                try
                {
                    var value = await AccountPage.Request("/api/account/api-keys", "POST", new JsonObject { ["name"] = trimmed, ["scope"] = scope });
                    if (AccountApiKey.From(value["item"] ?? value) is { } created) _keys.Insert(0, created); else await LoadAsync();
                    Render();
                    close();
                    ShowSecret(value.Text("key"));
                }
                catch (Exception failure)
                {
                    error.Text = AccountApiKey.Error(failure, "创建失败，请重试。");
                    saving = false; save.Enabled = true; save.Title = "创建";
                }
            }
            save = new V3Button("创建", Save, V3Button.Kind.Dark);
            name.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Save(); } };
            name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
            var body = VStack(0,
                V3DialogHead.Make("创建 API Key", "持有 Key 的工具可以读取你的简历、岗位和投递记录，请只填进你信任的工具。"),
                HStack(8, Label("名称", 13, Txt, Medium), Sans("用来区分用途，例如「Claude Code」", 12, Fnt)).Top(20),
                name.Top(8),
                Label("权限", 13, Txt, Medium).Top(18),
                options.Top(10),
                error.Top(10));
            return V3Dialog.Make(body, [new V3Button("取消", close), save], close, width: 520);
        });
    }

    void ShowSecret(string secret)
    {
        if (secret.Length == 0) return;
        V3Overlay.Show(XamlRoot, close =>
        {
            var field = new TextBox { Text = secret, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, BorderThickness = new Thickness(0), Background = Brush(Clear) };
            Quiet(field.Resources);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(field, "API Key");
            var box = new Border
            {
                Background = Brush(Field), CornerRadius = new CornerRadius(4), Padding = new Thickness(12, 4, 12, 4),
                Child = Columns(8, (Auto, Icon("lock", 12, Fnt).Align(v: VerticalAlignment.Center)), (Star(), field)),
            };
            var failed = Sans("无法自动复制，请手动选中后复制。", 12, Red);
            failed.Visibility = Visibility.Collapsed;
            V3Button? copy = null;
            copy = new V3Button("复制", () =>
            {
                if (Files.Copy(secret)) { copy!.Title = "已复制"; failed.Visibility = Visibility.Collapsed; }
                else { failed.Visibility = Visibility.Visible; field.Focus(FocusState.Programmatic); field.SelectAll(); }
            }, icon: "doc.on.doc");
            var body = VStack(0,
                V3DialogHead.Make("API Key 已创建", "请现在复制并保存。关闭后无法再次查看完整的 Key，丢失只能删除后重新创建。"),
                box.Top(20), failed.Top(8));
            return V3Dialog.Make(body, [copy, new V3Button("完成", close, V3Button.Kind.Dark)], close, width: 560);
        }, dismissible: false);
    }
}
