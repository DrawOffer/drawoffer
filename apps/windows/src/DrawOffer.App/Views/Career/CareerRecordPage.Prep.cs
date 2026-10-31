using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI.Text;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// Web `StationCard.PrepDialog`（Mac `CareerPrepSheet`）：560 宽；勾选、增加、生成准备清单。保存与生成由调用方完成，
/// 会话更新后调用 <see cref="Update"/> 重绘。用 `V3Overlay.Show(root, close => new CareerPrepSheet(...))` 打开。
/// </summary>
public sealed class CareerPrepSheet : UserControl
{
    static readonly Dictionary<string, string> Category = new()
    {
        ["intro"] = "自我介绍", ["project"] = "项目", ["technical"] = "技术", ["system_design"] = "系统设计", ["behavior"] = "行为", ["company"] = "公司", ["other"] = "其他",
    };

    JsonNode _session;
    bool _busy;
    readonly Action<IReadOnlyList<JsonNode>> _save;
    readonly Action _generate;
    readonly Action _close;
    string? _draft;
    readonly TextBox _input = new()
    {
        PlaceholderText = "比如：复习项目里的分片方案", FontSize = 13, FontFamily = SansFamily, Height = 30, MinHeight = 0, Padding = new Thickness(10, 5, 10, 0),
        BorderThickness = new Thickness(1), BorderBrush = Brush(0xCDDCF5), CornerRadius = new CornerRadius(8), Background = Brush(V3.White), MaxLength = 80,
    };

    public CareerPrepSheet(JsonNode session, bool busy, Action<IReadOnlyList<JsonNode>> save, Action generate, Action close)
    {
        (_session, _busy, _save, _generate, _close) = (session, busy, save, generate, close);
        _input.Named("新的准备事项");
        _input.TextChanged += (_, _) => _draft = _input.Text;
        _input.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Add(Items); } };
        Render();
    }

    public void Update(JsonNode session, bool busy) { _session = session; _busy = busy; Render(); }

    List<JsonNode> Items => _session.Items("prep_items");

    void Render()
    {
        var items = Items;
        var done = items.Count(x => x.Bool("done"));
        var canGenerate = _session.Text("status") == "scheduled" && (_session.Get("prep_generated_at") is null || _session.Get("prep_generated_at")!.GetValueKind() == System.Text.Json.JsonValueKind.Null);
        var head = VStack(4, Serif("准备清单", 20).Frame(height: 28), Sans(items.Count == 0 ? "还没有准备清单" : $"完成 {done} / {items.Count}", 12.5, PD.Body));
        head.Padding = new Thickness(28, 26, 28, 8);
        var body = new StackPanel { Padding = new Thickness(28, 14, 28, 20) };
        if (_busy && items.Count == 0) body.Children.Add(Sans("正在按岗位要求和简历生成…", 12.5, PD.Body).Top(14));
        if (!_busy && items.Count == 0 && canGenerate)
        {
            var copy = VStack(4, Sans("按这一站的类型、岗位要求和你的简历生成", 13, Txt, Medium), Sans("可以随时增删", 12, PD.Mute));
            var card = Spread(copy, new PDButton("生成准备清单", _generate, PDButton.Kind.Primary) { Enabled = !_busy }, 16);
            body.Children.Add(new Border { Child = card, Padding = new Thickness(18, 16, 18, 16), CornerRadius = new CornerRadius(14), Background = Brush(0xF4F7FD) });
        }
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var on = item.Bool("done");
            var circle = new Border
            {
                Width = 14, Height = 14, CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1.4),
                BorderBrush = Brush(on ? PD.Blue : Hex(0xC3D3F0)), Background = Brush(on ? PD.Blue : V3.White),
                Child = on ? Icon("checkmark", 7, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) : null,
            };
            var position = index;
            var toggle = Tappable(new Border { Width = 22, Height = 22, Child = circle.Align(HorizontalAlignment.Center, VerticalAlignment.Center), Background = Brush(Clear) },
                () => _save(Toggled(items, position)), item.Text("title"), () => !_busy);
            if (on) Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(toggle, "已选中");
            var title = Sans(item.Text("title"), 13, on ? PD.Mute : PD.Ink, Medium).Wrap();
            if (on) title.TextDecorations = TextDecorations.Strikethrough;
            var row = Columns(10, (Auto, toggle), (Px(54), Sans(Category.GetValueOrDefault(item.Text("category"), "其他"), 11, PD.BlueText, Medium)),
                (Star(), title), (Auto, Sans(item.Text("reason"), 12, PD.Mute)));
            foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
            body.Children.Add(new Border { Child = row, MinHeight = 44, BorderBrush = Brush(0xEEF2F9), BorderThickness = new Thickness(0, 0, 0, 1) });
        }
        if (_draft is not null)
        {
            var row = Columns(10, (Px(22), new Border()), (Px(54), Sans("其他", 11, PD.BlueText, Medium)), (Star(), Detach(_input)));
            foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
            body.Children.Add(new Border { Child = row, MinHeight = 44 });
        }
        var scroll = new ScrollViewer { Content = body, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var add = Tappable(Sans("+ 添加一项", 12.5, PD.Ink, Medium), () =>
        {
            if (_draft is null) { _draft = ""; _input.Text = ""; Render(); _input.Focus(FocusState.Programmatic); }
            else Add(items);
        }, "+ 添加一项", () => !(_busy || items.Count >= 12));
        add.Opacity = _busy || items.Count >= 12 ? 0.5 : 1;
        var close = new PDButton("关闭", () => { if (_draft is { } draft && draft.Trim().Length > 0) Add(items); _close(); });
        var foot = Spread(add, close, 10);
        foot.Padding = new Thickness(28, 16, 28, 20);
        var stack = new Grid();
        stack.RowDefinitions.Add(new RowDefinition { Height = Auto });
        stack.RowDefinitions.Add(new RowDefinition { Height = Auto });
        stack.RowDefinitions.Add(new RowDefinition { Height = Star() });
        stack.RowDefinitions.Add(new RowDefinition { Height = Auto });
        stack.RowDefinitions.Add(new RowDefinition { Height = Auto });
        UIElement[] rows = [head, Divider(Hex(0xECEAE4)), scroll, Divider(Hex(0xECEAE4)), foot];
        for (var i = 0; i < rows.Length; i++) { Grid.SetRow((FrameworkElement)rows[i], i); stack.Children.Add(rows[i]); }
        Content = V3Dialog.Frame(stack, 560);
    }

    static List<JsonNode> Toggled(List<JsonNode> items, int index) => items.Select((item, position) =>
    {
        var copy = item.DeepClone();
        if (position == index && copy is JsonObject fields) fields["done"] = !item.Bool("done");
        return copy;
    }).ToList();

    void Add(List<JsonNode> items)
    {
        var title = (_draft ?? "").Trim();
        _draft = null;
        if (title.Length == 0) { Render(); return; }
        var next = items.Select(x => x.DeepClone()).ToList();
        next.Add(new JsonObject { ["title"] = Prefix(title, 80), ["category"] = "other", ["reason"] = null, ["done"] = false });
        _save(next);
        Render();
    }
}
