using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Account;

/// <summary>`/account` 与 `/account/career-profile`：求职画像是账号下的独立页面，左上角返回账号设置。</summary>
public sealed class AccountPage : UserControl
{
    public AccountPage()
    {
        var shell = WorkspaceShell.Current;
        void Show(bool career)
        {
            shell.CareerProfileRequested = career;
            Content = career ? new CareerProfileView(() => Show(false)) : new AccountView(() => Show(true));
        }
        Show(shell.CareerProfileRequested);
    }

    internal static Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null) =>
        App.Session.Api.CareerRequestAsync(path, method, null, body);
}

/// <summary>
/// 账号设置（Windows 稿 01 页 04.01 定稿）：居中 560 宽的一列——头像 84 + 昵称（点笔就地改，04.07）
/// → 额度（当前方案 / 可用积分，打开会员与积分弹窗，04.05/04.06）→ 账号（联系邮箱就地展开 04.09、界面语言行内下拉 04.04）
/// → API Key（04.11）→ 退出登录（确认 04.10，红色胶囊）→ 隐私政策 · 用户协议。
/// 桌面端不提供修改密码、微信绑定和注销账号（后端只接受 Web Cookie）。
/// </summary>
public sealed class AccountView : UserControl
{
    readonly Action _openCareerProfile;
    readonly StackPanel _column = new() { HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(0, 24, 0, 48) };
    JsonNode? _profile, _preferences;
    BillingSummary? _billing;
    ImageSource? _avatar;
    bool _loading = true, _failed, _savingPreference, _editingName, _editingEmail, _disposed;
    string _account = "";

    public AccountView(Action openCareerProfile)
    {
        _openCareerProfile = openCareerProfile;
        Background = Brush(White);
        Content = Scroll(_column);
        SizeChanged += (_, e) => _column.Width = Math.Min(560, Math.Max(320, e.NewSize.Width - 64));
        Loaded += async (_, _) => { _account = Account; App.Session.PropertyChanged += OnSession; Render(); await LoadAsync(); };
        Unloaded += (_, _) => { _disposed = true; App.Session.PropertyChanged -= OnSession; };
    }

    static string Account => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User?.Id ?? "" : "";
    JsonNode? User => _profile?["user"];
    string Initial => System.Globalization.StringInfo.GetNextTextElement(User.Text("nickname").Trim() is { Length: > 0 } name ? name : "我");

    async void OnSession(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (_account == Account) return;
        _account = Account;
        _profile = _preferences = null; _billing = null; _avatar = null; _loading = true;
        Render();
        await LoadAsync();
    }

    async Task LoadAsync()
    {
        var owner = Account;
        if (owner.Length == 0) return;
        _failed = false;
        var preferences = LoadPreferencesAsync();
        var billing = LoadBillingAsync();
        try
        {
            var value = await AccountPage.Request("/api/account/profile");
            if (owner != Account || _disposed) return;
            _profile = value;
            await LoadAvatarAsync();
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (_profile is null) _failed = true;
        }
        await Task.WhenAll(preferences, billing);
        _loading = false;
        if (!_disposed) Render();
    }

    async Task LoadPreferencesAsync()
    {
        try { _preferences = await AccountPage.Request("/api/account/preferences"); } catch { }
    }

    async Task LoadBillingAsync()
    {
        try { _billing = BillingSummary.From(await AccountPage.Request("/api/billing/summary")); } catch { }
    }

    async Task LoadAvatarAsync()
    {
        var path = User.Text("avatar_url");
        if (path.Length == 0) { _avatar = null; return; }
        if (path.StartsWith("/api/auth/default-avatar", StringComparison.Ordinal)) { _avatar = new BitmapImage(new Uri("ms-appx:///Assets/Branding/default-avatar.png")); return; }
        if (App.Session.Api is not HttpApiClient client) return;
        try { _avatar = await Files.BitmapAsync(await client.Coordinator.AccountAvatarAsync(path)); } catch { _avatar = null; }
    }

    void Apply(JsonNode next)
    {
        if (_profile is null) return;
        var avatarChanged = next.Text("avatar_url") != User.Text("avatar_url");
        _profile["user"] = next.DeepClone();
        if (avatarChanged) App.Session.UpdateAvatar(next.Text("avatar_url") is { Length: > 0 } url ? url : null);
        _ = Refresh();
        async Task Refresh() { await LoadAvatarAsync(); Render(); }
    }

    void Render()
    {
        _column.Children.Clear();
        if (_loading && _profile is null) { _column.Children.Add(new V3Loading("正在加载个人资料…").Top(160)); return; }
        if (_failed && _profile is null)
        {
            _column.Children.Add(VStack(10,
                Label("暂时无法读取个人资料", 18, Txt, Semibold).Align(HorizontalAlignment.Center),
                Sans("请检查网络连接后重新加载。", 13, Sub).Align(HorizontalAlignment.Center),
                new V3Button("重新加载", () => { _loading = true; Render(); _ = LoadAsync(); }).Align(HorizontalAlignment.Center).Top(6)).Top(160));
            return;
        }
        // 头像 84（墨黑底白字），点开换头像（04.08）
        var avatar = AvatarCircle.Make(_avatar, Initial, 84).Align(HorizontalAlignment.Center).OnTap(OpenAvatar, "更换头像").Tip("更换头像");
        _column.Children.Add(avatar);
        _column.Children.Add(NameField().Top(18));
        _column.Children.Add(Group("额度",
            Row("当前方案", _billing?.TierLabel ?? "—", () => PlansDialog.Show(WorkspaceShell.Current)),
            Row("可用积分", _billing?.AvailableText ?? "—", () => PlansDialog.Show(WorkspaceShell.Current, "credits"), warn: _billing?.Exhausted == true)).Top(32));
        var note = HStack(0, Sans("联系邮箱只用于找回账号；网申要填的电话、邮箱在", 12, Fnt),
            Sans("「求职画像」", 12, Link).OnTap(_openCareerProfile, "求职画像"), Sans("里。", 12, Fnt)).Top(8);
        _column.Children.Add(Group("账号", EmailRow(), LanguageRow(), note).Top(32));
        _column.Children.Add(new AccountApiKeySection().Top(32));
        var logout = Spread(VStack(3, Label("退出登录", 14, Txt), Sans("只退出当前设备，其他设备不受影响", 12, Fnt)),
            new V3Button("退出登录", ConfirmLogout, V3Button.Kind.Danger));
        _column.Children.Add(new Border { Child = logout, Height = 62, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 1) }.Top(40));
        _column.Children.Add(HStack(10,
            Sans("隐私政策", 12, Blue).OnTap(() => WebBridge.Open("/privacy"), "隐私政策"),
            Sans("·", 12, Hex(0xA8A8A4)),
            Sans("用户协议", 12, Blue).OnTap(() => WebBridge.Open("/terms"), "用户协议")).Align(HorizontalAlignment.Center).Top(32));
    }

    /// <summary>分组：15/500 标题，下方 6 起细线，行 50 高、行间细线。</summary>
    static StackPanel Group(string title, params UIElement[] rows)
    {
        var stack = VStack(0, Label(title, 15, Txt, Medium).Frame(height: 20).Pad(0, 0, 0, 6), Divider());
        foreach (var row in rows) stack.Children.Add(row);
        return stack;
    }

    /// <summary>一行设置：50 高，左 14 标签，右 14 #55554F 值 + 细箭头；整行可点，悬停只把箭头加深（不加灰底）。</summary>
    static Border Row(string label, string? value, Action? action, bool warn = false, UIElement? trailing = null)
    {
        var chevron = Icon("chevron.right", 10, Fnt2);
        var right = HStack(8, value is null ? null : Label(value, 14, warn ? Red : Sub), value is null ? null : chevron, trailing);
        var row = new Border { Height = 50, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1), Background = Brush(Clear), Child = Spread(Label(label, 14, Txt), right, 12) };
        if (action is not null && value is not null)
        {
            row.OnHover(h => chevron.Foreground = Brush(h ? Sub : Fnt2));
            row.OnTap(action, $"{label}：{value}");
        }
        return row;
    }

    /// <summary>04.01 / 04.07：24/600 昵称 + 小笔；点笔就地变成墨黑描边输入框，回车保存、Esc 取消。</summary>
    UIElement NameField()
    {
        var name = User.Text("nickname");
        if (!_editingName)
        {
            var pencil = new V3IconButton("pencil", "修改昵称", () => { _editingName = true; Render(); }, 22, 12, Fnt);
            return HStack(6, Label(name.Length > 0 ? name : "未设置昵称", 24, Txt, Semibold), pencil).Align(HorizontalAlignment.Center).Pad(28, 0, 0, 0);
        }
        var box = Input("", name, 50);
        box.Width = 240; box.Height = 40; box.FontSize = 20; box.TextAlignment = TextAlignment.Center; box.BorderBrush = Brush(Txt);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "昵称");
        var hint = Sans("回车保存 · Esc 取消 · 最多 50 个字", 12, Fnt).Align(HorizontalAlignment.Center);
        var saving = false;
        async void Commit()
        {
            if (saving) return;
            var trimmed = box.Text.Trim();
            if (trimmed.Length is 0 or > 50) { hint.Text = "昵称需要 1–50 个字符。"; hint.Foreground = Brush(Red); box.BorderBrush = Brush(Red); return; }
            if (trimmed == name) { _editingName = false; Render(); return; }
            saving = true; box.IsEnabled = false;
            try
            {
                Apply(await AccountPage.Request("/api/account/profile", "PATCH", new JsonObject { ["nickname"] = trimmed }));
                _editingName = false;
                V3Toast.Show("昵称已保存");
                Render();
            }
            catch (Exception error)
            {
                hint.Text = ErrorText.From(error, "昵称保存失败，请稍后重试。"); hint.Foreground = Brush(Red); box.BorderBrush = Brush(Red);
                saving = false; box.IsEnabled = true;
            }
        }
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Commit(); }
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; _editingName = false; Render(); }
        };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        return VStack(8, box.Align(HorizontalAlignment.Center), hint);
    }

    /// <summary>04.09：联系邮箱就地展开——输入框 + 取消 + 墨黑小「保存」，保存后收起；留空即清除。</summary>
    UIElement EmailRow()
    {
        var email = User.Text("contact_email");
        if (!_editingEmail) return Row("联系邮箱", email.Length > 0 ? email : "未设置", () => { _editingEmail = true; Render(); });
        var box = Input("you@example.com", email);
        box.BorderBrush = Brush(Txt);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "联系邮箱");
        var hint = Sans("留空保存即可清除联系邮箱。", 12, Fnt);
        V3Button? save = null;
        var saving = false;
        async void Commit()
        {
            if (saving) return;
            var trimmed = box.Text.Trim();
            if (trimmed.Length > 0 && !Regex.IsMatch(trimmed, @"^[^\s@]+@[^\s@]+\.[^\s@]+$")) { hint.Text = "请输入有效的邮箱地址。"; hint.Foreground = Brush(Red); return; }
            saving = true; save!.Enabled = false; save.Title = "保存中…";
            try
            {
                var result = await AccountPage.Request("/api/account/contact-email", "PUT", new JsonObject { ["email"] = trimmed.Length == 0 ? null : trimmed });
                var next = User!.DeepClone();
                next["contact_email"] = result["contact_email"]?.DeepClone();
                Apply(next);
                _editingEmail = false;
                V3Toast.Show(trimmed.Length == 0 ? "联系邮箱已清除" : "联系邮箱已保存");
                Render();
            }
            catch (Exception error)
            {
                hint.Text = ErrorText.From(error, "联系邮箱保存失败，请重试。"); hint.Foreground = Brush(Red);
                saving = false; save.Enabled = true; save.Title = "保存";
            }
        }
        save = new V3Button("保存", Commit, V3Button.Kind.Dark, height: 28);
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Commit(); }
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; _editingEmail = false; Render(); }
        };
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        var line = Columns(12, (Star(), box), (Auto, new V3Button("取消", () => { _editingEmail = false; Render(); }, V3Button.Kind.Text, height: 28)), (Auto, save));
        return new Border
        {
            BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 16, 0, 14),
            Child = VStack(12, Label("联系邮箱", 14, Txt), line, hint),
        };
    }

    /// <summary>04.04：界面语言行内小下拉（ComboBox 观感的文字 + 箭头，点开 MenuFlyout），选完立即生效。</summary>
    UIElement LanguageRow()
    {
        (string id, string label)[] options = [("zh-CN", "简体中文"), ("en-US", "English")];
        var value = _preferences.Text("locale") is { Length: > 0 } locale ? locale : "zh-CN";
        var current = options.FirstOrDefault(x => x.id == value).label ?? "简体中文";
        var trigger = HStack(6, Label(current, 14, Sub), Icon("chevron.down", 10, Fnt));
        trigger.Opacity = _preferences is null || _savingPreference ? 0.5 : 1;
        trigger.OnTap(() =>
        {
            if (_preferences is null || _savingPreference) return;
            var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
            foreach (var option in options)
            {
                var item = new ToggleMenuFlyoutItem { Text = option.label, IsChecked = option.id == value };
                var id = option.id;
                item.Click += async (_, _) => { if (id != value) await SavePreferenceAsync(id); };
                menu.Items.Add(item);
            }
            menu.ShowAt(trigger);
        }, "界面语言");
        return Row("界面语言", null, null, trailing: trigger);
    }

    async Task SavePreferenceAsync(string locale)
    {
        if (_savingPreference) return;
        _savingPreference = true;
        Render();
        try { _preferences = await AccountPage.Request("/api/account/preferences", "PATCH", new JsonObject { ["locale"] = locale }); }
        catch (Exception error) { V3Toast.Show(ErrorText.From(error, "偏好保存失败，请重试。"), V3Toast.Kind.Error); }
        _savingPreference = false;
        Render();
    }

    /// <summary>04.10 退出登录确认：只退出当前设备（带设备名）。</summary>
    void ConfirmLogout()
    {
        var device = _profile?["current_session"].Text("device_label") ?? "";
        V3Overlay.Show(XamlRoot, close =>
        {
            V3Button? confirm = null;
            confirm = new V3Button("退出登录", async () =>
            {
                confirm!.Enabled = false; confirm.Title = "正在退出…";
                await App.Session.SignOutCommand.ExecuteAsync(null);
                close();
            }, V3Button.Kind.Dark);
            return V3Dialog.Make(V3DialogHead.Make("退出登录？", device.Length == 0 ? "只退出当前设备，其他设备上的登录不受影响。" : $"只退出当前设备（{device}），其他设备上的登录不受影响。"),
                [new V3Button("取消", close), confirm], close);
        });
    }

    void OpenAvatar() => AvatarDialog.Show(XamlRoot, User ?? new JsonObject(), _avatar, Initial, next => { Apply(next); Render(); });
}

/// <summary>
/// 04.08 换头像（ContentDialog 460 宽）：412×240 浅灰裁剪区，圆窗直径 200，圆窗外 45% 墨黑遮罩 + 白色细描边，
/// 底部提示胶囊；拖动调整位置、滑块缩放；按圆窗取原图正方形缩到 512 输出 PNG（与 Web `createAvatarCropDataUrl` 一致）。
/// </summary>
static class AvatarDialog
{
    const double CropWidth = 412, CropHeight = 240, WindowSize = 200;

    public static void Show(XamlRoot root, JsonNode user, ImageSource? current, string initial, Action<JsonNode> updated)
    {
        V3Overlay.Show(root, close =>
        {
            AvatarCrop.Draft? draft = null;
            byte[]? bytes = null;
            ImageSource? picked = null;
            var remove = false;
            var saving = false;
            var scale = WindowSize / AvatarCrop.Window;
            var crop = new Canvas { Width = CropWidth, Height = CropHeight, Background = Brush(Field) };
            var cropFrame = new Border { Child = crop, Width = CropWidth, Height = CropHeight, CornerRadius = new CornerRadius(8), ManipulationMode = Microsoft.UI.Xaml.Input.ManipulationModes.TranslateX | Microsoft.UI.Xaml.Input.ManipulationModes.TranslateY };
            var zoom = new Slider { Minimum = AvatarCrop.MinZoom, Maximum = AvatarCrop.MaxZoom, StepFrequency = 0.01, Value = 1, IsEnabled = false };
            Quiet(zoom.Resources);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(zoom, "缩放");
            var error = Sans("", 12, Red);
            error.Visibility = Visibility.Collapsed;
            V3Button? save = null, removeButton = null;

            bool Changed() => draft is not null || (remove && user.Text("avatar_url").Length > 0);

            void Paint()
            {
                crop.Children.Clear();
                if (draft is { } d && picked is not null)
                {
                    var layout = AvatarCrop.Measure(d);
                    var image = new Image { Source = picked, Width = layout.RenderedWidth * scale, Height = layout.RenderedHeight * scale, Stretch = Stretch.Fill };
                    Canvas.SetLeft(image, (CropWidth - image.Width) / 2 + d.OffsetX * scale);
                    Canvas.SetTop(image, (CropHeight - image.Height) / 2 + d.OffsetY * scale);
                    crop.Children.Add(image);
                }
                else
                {
                    var avatar = AvatarCircle.Make(remove ? null : current, initial, WindowSize);
                    Canvas.SetLeft(avatar, (CropWidth - WindowSize) / 2);
                    Canvas.SetTop(avatar, (CropHeight - WindowSize) / 2);
                    crop.Children.Add(avatar);
                }
                var mask = new Microsoft.UI.Xaml.Shapes.Path
                {
                    Fill = Brush(Alpha(Txt, 0.45)), IsHitTestVisible = false,
                    Data = new GeometryGroup
                    {
                        FillRule = FillRule.EvenOdd,
                        Children =
                        {
                            new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, CropWidth, CropHeight) },
                            new EllipseGeometry { Center = new Windows.Foundation.Point(CropWidth / 2, CropHeight / 2), RadiusX = WindowSize / 2, RadiusY = WindowSize / 2 },
                        },
                    },
                };
                crop.Children.Add(mask);
                var ring = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = WindowSize, Height = WindowSize, Stroke = Brush(White), StrokeThickness = 1.4, IsHitTestVisible = false };
                Canvas.SetLeft(ring, (CropWidth - WindowSize) / 2);
                Canvas.SetTop(ring, (CropHeight - WindowSize) / 2);
                crop.Children.Add(ring);
                var pill = new Border
                {
                    Height = 22, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(11), Background = Brush(Alpha(Txt, 0.8)),
                    Child = Sans(draft is null ? "点击选择图片" : "拖动调整位置", 11, White, Medium).Align(v: VerticalAlignment.Center), IsHitTestVisible = false,
                };
                pill.Loaded += (_, _) => Canvas.SetLeft(pill, (CropWidth - pill.ActualWidth) / 2);
                Canvas.SetTop(pill, CropHeight - 32);
                crop.Children.Add(pill);
                zoom.IsEnabled = draft is not null && !saving;
                if (save is not null) save.Enabled = !saving && Changed();
                if (removeButton is not null) removeButton.Enabled = !saving && (draft is not null || (!remove && current is not null));
            }

            async Task Pick()
            {
                var file = await Files.PickAsync("png", "jpg", "jpeg", "webp");
                if (file is null) return;
                var properties = await file.GetBasicPropertiesAsync();
                if (properties.Size > 10 * 1024 * 1024) { V3Toast.Show("头像图片不能超过 10MB。", V3Toast.Kind.Error); return; }
                var data = await Files.ReadAsync(file);
                var bitmap = await Files.BitmapAsync(data);
                if (bitmap is null || bitmap.PixelWidth <= 0 || bitmap.PixelHeight <= 0) { V3Toast.Show("头像图片无法读取，请选择其他图片。", V3Toast.Kind.Error); return; }
                bytes = data; picked = bitmap; remove = false;
                draft = new AvatarCrop.Draft(bitmap.PixelWidth, bitmap.PixelHeight);
                zoom.Value = 1;
                error.Visibility = Visibility.Collapsed;
                Paint();
            }

            cropFrame.Tapped += async (_, _) => { if (draft is null && !saving) await Pick(); };
            cropFrame.ManipulationDelta += (_, e) =>
            {
                if (draft is not { } d || saving) return;
                draft = AvatarCrop.Clamp(d with { OffsetX = d.OffsetX + e.Delta.Translation.X / scale, OffsetY = d.OffsetY + e.Delta.Translation.Y / scale });
                Paint();
            };
            zoom.ValueChanged += (_, _) => { if (draft is { } d) { draft = AvatarCrop.Clamp(d with { Zoom = zoom.Value }); Paint(); } };

            async void Save()
            {
                if (saving || !Changed()) return;
                saving = true; save!.Title = "保存中…"; error.Visibility = Visibility.Collapsed; Paint();
                var latest = user.DeepClone();
                try
                {
                    if (draft is { } d && bytes is not null)
                    {
                        var png = await CropPngAsync(bytes, d);
                        var result = await AccountPage.Request("/api/account/avatar", "PUT", new JsonObject { ["fileName"] = "avatar.png", ["dataUrl"] = "data:image/png;base64," + Convert.ToBase64String(png) });
                        latest["avatar_url"] = result["url"]?.DeepClone();
                        updated(latest);
                        V3Toast.Show("头像已更新");
                    }
                    else
                    {
                        await AccountPage.Request("/api/account/avatar", "DELETE");
                        latest["avatar_url"] = null;
                        updated(latest);
                        V3Toast.Show("头像已移除");
                    }
                    close();
                }
                catch (Exception failure)
                {
                    error.Text = ErrorText.From(failure, draft is null ? "头像删除失败，请稍后重试。" : "头像处理或上传失败，请重试。");
                    error.Visibility = Visibility.Visible;
                    saving = false; save.Title = "保存"; Paint();
                }
            }

            save = new V3Button("保存", Save, V3Button.Kind.Dark);
            removeButton = new V3Button("移除头像", () => { draft = null; picked = null; bytes = null; remove = true; Paint(); }, V3Button.Kind.Text);
            removeButton.Tint = Red;
            Paint();
            var body = VStack(0,
                V3DialogHead.Make("换头像", "支持 JPG、PNG、WebP，最大 10 MB。"),
                cropFrame.Top(20),
                Columns(14, (Auto, Sans("缩放", 13, Sub).Align(v: VerticalAlignment.Center)), (Star(), zoom)).Top(16),
                error.Top(8));
            return V3Dialog.Make(body, [new V3Button("取消", close), save], close, width: 460,
                left: [new V3Button("重新选择", async () => await Pick()), removeButton]);
        });
    }

    static async Task<byte[]> CropPngAsync(byte[] bytes, AvatarCrop.Draft draft)
    {
        using var input = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        using (var writer = new Windows.Storage.Streams.DataWriter(input.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
        input.Seek(0);
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(input);
        var source = AvatarCrop.Source(draft);
        var x = (uint)Math.Floor(source.X);
        var y = (uint)Math.Floor(source.Y);
        var transform = new Windows.Graphics.Imaging.BitmapTransform
        {
            Bounds = new Windows.Graphics.Imaging.BitmapBounds
            {
                X = x, Y = y,
                Width = (uint)Math.Min(Math.Ceiling(source.Size), decoder.PixelWidth - x),
                Height = (uint)Math.Min(Math.Ceiling(source.Size), decoder.PixelHeight - y),
            },
        };
        var pixels = await decoder.GetPixelDataAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, transform,
            Windows.Graphics.Imaging.ExifOrientationMode.IgnoreExifOrientation, Windows.Graphics.Imaging.ColorManagementMode.ColorManageToSRgb);
        using var output = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, output);
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            transform.Bounds.Width, transform.Bounds.Height, 96, 96, pixels.DetachPixelData());
        encoder.BitmapTransform.ScaledWidth = encoder.BitmapTransform.ScaledHeight = (uint)AvatarCrop.Output;
        await encoder.FlushAsync();
        output.Seek(0);
        var result = new byte[(int)output.Size];
        using var reader = new Windows.Storage.Streams.DataReader(output);
        await reader.LoadAsync((uint)result.Length);
        reader.ReadBytes(result);
        return result;
    }
}
