using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>原生端没有的能力在默认浏览器打开 Web 对应页面（Mac `WebBridge`）。网页使用自己的登录态，不传递桌面凭据。</summary>
public static class WebBridge
{
    public static void Open(string path)
    {
        if (App.Session.Api is not HttpApiClient client || !path.StartsWith('/')) return;
        var uri = new Uri(client.Coordinator.Origin, path);
        if (uri.Scheme is "https" or "http") _ = Windows.System.Launcher.LaunchUriAsync(uri);
    }
}

public static class DesktopClient
{
    public static string Version => typeof(DesktopClient).Assembly.GetName().Version is { } version ? $"{version.Major}.{version.Minor}.{version.Build}" : "0.1.0";
}

/// <summary>
/// 登录页（Windows 稿 01 页「02 · 登录页」8:1650）：整窗页面盖住侧栏。左上 logo + 品牌字（Brand / Lockup）+「求职工作台」，
/// 右上「暂不登录」回到游客模式；中间一列：标题 26/600 →说明 13 →176 方框二维码 →提示 →协议勾选；底部版权。
/// A 未勾选协议：占位码虚化，叠「请先勾选下方协议」；B 勾选后取小程序码并轮询；手机确认后只显示加载（不画「已扫码」）；
/// D 过期换成「二维码已过期 · 刷新二维码」。开发环境（服务端 password_login_enabled）在客户端内用邮箱密码登录（稿 E），不跳浏览器。
/// </summary>
public sealed class SignInView : Grid
{
    enum QrState { Idle, Loading, Ready, Confirming, Expired, Failed }

    readonly Action? _dismiss;
    readonly Border _column = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    JsonNode? _capabilities;
    bool _capabilitiesLoaded;
    bool _agreed;
    QrState _state = QrState.Idle;
    BitmapImage? _qr;
    string? _message;
    CancellationTokenSource? _poll;
    bool _submitting;
    string _email = "", _password = "";

    public SignInView(Action? dismiss = null)
    {
        _dismiss = dismiss;
        Background = Brush(V3.White);
        Children.Add(_column);

        var brand = HStack(10,
            new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/lockup.png")), Height = 22, Stretch = Stretch.Uniform },
            Sans("求职工作台", 12, Fnt));
        var top = new Grid { Height = 48, Margin = new Thickness(24, 40, 24, 0), VerticalAlignment = VerticalAlignment.Top };
        top.Children.Add(brand.Align(HorizontalAlignment.Left, VerticalAlignment.Center));
        if (dismiss is not null)
        {
            var skip = new V3Button("暂不登录", dismiss, V3Button.Kind.Text);
            skip.HorizontalAlignment = HorizontalAlignment.Right;
            skip.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(skip);
        }
        Children.Add(top);
        Children.Add(Sans("© 2026 DrawOffer", 12, Fnt2).Align(HorizontalAlignment.Center, VerticalAlignment.Bottom).Pad(0, 0, 0, 20));
        KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape && dismiss is not null) { e.Handled = true; dismiss(); } };

        App.Session.PropertyChanged += OnSession;
        Loaded += async (_, _) => await LoadCapabilitiesAsync();
        Unloaded += (_, _) => { App.Session.PropertyChanged -= OnSession; _poll?.Cancel(); };
        Render();
    }

    void OnSession(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => DispatcherQueue.TryEnqueue(Render);

    bool Wechat => _capabilities?["wechat_login_enabled"]?.GetValue<bool>() ?? true;
    bool PasswordMode => !Wechat && _capabilities?["password_login_enabled"]?.GetValue<bool>() == true;

    async Task LoadCapabilitiesAsync()
    {
        try { if (App.Session.Api is HttpApiClient client) _capabilities = await client.Coordinator.CapabilitiesAsync(); }
        catch { _capabilities = null; }
        _capabilitiesLoaded = true;
        Render();
    }

    void Render()
    {
        _column.Child = PasswordMode ? PasswordColumn() : WechatColumn();
    }

    // MARK: 微信扫码（稿 A / B / D）

    StackPanel WechatColumn()
    {
        var column = VStack(0,
            Label("微信扫码登录 DrawOffer", 26, Txt, Semibold).Align(HorizontalAlignment.Center),
            Sans("首次扫码会自动创建账号，无需填写表单。", 13, Sub).Align(HorizontalAlignment.Center).Top(8),
            Box().Top(28),
            Sans(Wechat ? "打开微信扫一扫，在手机上确认登录" : " ", 12, Fnt).Align(HorizontalAlignment.Center).Top(16),
            Agreement().Top(28));
        if ((_message ?? App.Session.ErrorMessage) is { } error)
            column.Children.Add(Sans(error, 12, Red).Wrap().Also(x => { x.TextAlignment = TextAlignment.Center; x.MaxWidth = 320; }).Align(HorizontalAlignment.Center).Top(14));
        if (App.Session.Phase == SessionViewModel.SessionPhase.Restoring)
            column.Children.Add(V3Loading.TextLink("重试恢复登录", () => _ = App.Session.RestoreAsync(), 12).Align(HorizontalAlignment.Center).Top(8));
        return column;
    }

    /// <summary>二维码框：176×176 白底、圆角 8、#E4E4E0 细边。</summary>
    Border Box()
    {
        var inner = new Grid();
        if (!Wechat)
        {
            inner.Children.Add(_capabilitiesLoaded
                ? VStack(10, Sans("登录服务暂时不可用，请稍后重试。", 12, Sub).Wrap().Also(x => x.TextAlignment = TextAlignment.Center),
                    new V3Button("重试", async () => { _capabilitiesLoaded = false; Render(); await LoadCapabilitiesAsync(); }, height: 28).Align(HorizontalAlignment.Center)).Pad(14, 0, 14, 0).Align(v: VerticalAlignment.Center)
                : Ring());
        }
        else if (!_agreed)
        {
            var placeholder = QrPlaceholder();
            placeholder.Opacity = 0.55;
            inner.Children.Add(placeholder);
            inner.Children.Add(new Border
            {
                Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
                BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Child = VStack(3, Sans("请先勾选下方协议", 13, Txt, Medium).Align(HorizontalAlignment.Center), Sans("勾选后即可扫码登录", 11, Sub).Align(HorizontalAlignment.Center)),
            }.Elevate(6));
        }
        else
        {
            inner.Children.Add(_state switch
            {
                QrState.Ready when _qr is not null => new Image { Source = _qr, Width = 152, Height = 152, Stretch = Stretch.Uniform }.Tip("微信登录二维码"),
                QrState.Expired or QrState.Failed => VStack(10,
                    Sans(_state == QrState.Expired ? "二维码已过期" : "暂时无法获取二维码", 13, Txt, Medium).Align(HorizontalAlignment.Center),
                    new V3Button(_state == QrState.Expired ? "刷新二维码" : "重试", StartQr, V3Button.Kind.Dark, height: 28).Align(HorizontalAlignment.Center)).Align(v: VerticalAlignment.Center),
                _ => Ring(),
            });
        }
        return new Border
        {
            Width = 176, Height = 176, CornerRadius = new CornerRadius(8), Background = Brush(V3.White), BorderBrush = Brush(Cl),
            BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, Child = inner,
        };
    }

    static ProgressRing Ring() => new() { IsActive = true, Width = 20, Height = 20, Foreground = Brush(Txt), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    /// <summary>协议：CheckBox + 12 号灰字，《用户协议》《隐私政策》用 #2E53AA 文字链。</summary>
    StackPanel Agreement()
    {
        var check = new CheckBox { IsChecked = _agreed, MinWidth = 0, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        Quiet(check.Resources);
        check.Resources["CheckBoxCheckBackgroundFillChecked"] = Brush(Txt);
        check.Resources["CheckBoxCheckBackgroundFillCheckedPointerOver"] = Brush(Hex(0x2F2F2C));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(check, "我已阅读并同意用户协议和隐私政策");
        check.Checked += (_, _) => SetAgreed(true);
        check.Unchecked += (_, _) => SetAgreed(false);
        var text = HStack(0,
            Sans("我已阅读并同意", 12, Sub).OnTap(() => SetAgreed(!_agreed)),
            Sans("《用户协议》", 12, Link).OnTap(() => WebBridge.Open("/terms"), "用户协议"),
            Sans("和", 12, Sub),
            Sans("《隐私政策》", 12, Link).OnTap(() => WebBridge.Open("/privacy"), "隐私政策"));
        return HStack(4, check, text).Align(HorizontalAlignment.Center);
    }

    void SetAgreed(bool value)
    {
        if (_agreed == value) return;
        _agreed = value;
        if (value && Wechat) StartQr();
        else { _poll?.Cancel(); _state = QrState.Idle; }
        Render();
    }

    /// <summary>勾选后取码并按后端给的间隔轮询；确认后换取令牌，过期或取消就停在 D 态等用户刷新。</summary>
    async void StartQr()
    {
        _poll?.Cancel();
        var cts = _poll = new CancellationTokenSource();
        if (App.Session.Api is not HttpApiClient client) return;
        _message = null;
        _state = QrState.Loading;
        Render();
        DesktopLoginChallenge challenge;
        try { challenge = await client.Coordinator.BeginLoginAsync(DesktopClient.Version, cts.Token); }
        catch
        {
            if (cts.IsCancellationRequested) return;
            _state = QrState.Failed; Render(); return;
        }
        try
        {
            var bytes = Convert.FromBase64String(challenge.Qrcode["qr_base64"]?.GetValue<string>() ?? "");
            var bitmap = new BitmapImage();
            using (var stream = new MemoryStream(bytes).AsRandomAccessStream()) await bitmap.SetSourceAsync(stream);
            _qr = bitmap;
        }
        catch { _state = QrState.Failed; Render(); return; }
        _state = QrState.Ready;
        Render();
        var expires = Math.Max(30, challenge.Qrcode["expires_in"]?.GetValue<int>() ?? 300);
        var interval = Math.Max(1, challenge.Qrcode["poll_interval_seconds"]?.GetValue<int>() ?? 2);
        var deadline = DateTime.UtcNow.AddSeconds(expires);
        while (!cts.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(interval), cts.Token); } catch { return; }
            if (DateTime.UtcNow >= deadline) { _state = QrState.Expired; Render(); return; }
            string status;
            try { status = await client.Coordinator.LoginStatusAsync(challenge, cts.Token); } catch { if (cts.IsCancellationRequested) return; continue; }
            switch (status)
            {
                case "confirmed" or "consumed":
                    _state = QrState.Confirming;
                    Render();
                    try { await App.Session.CompleteDesktopLoginAsync(challenge, cts.Token); }
                    catch
                    {
                        if (cts.IsCancellationRequested) return;
                        _message = "登录未完成，请刷新二维码后重新扫码。";
                        _state = QrState.Expired;
                        Render();
                    }
                    return;
                case "expired" or "cancelled":
                    _state = QrState.Expired; Render(); return;
            }
        }
    }

    /// <summary>A 态占位码：三个定位角 + 固定伪随机方块，#D6D6D1，只作示意（真码在勾选后才取）。</summary>
    static Canvas QrPlaceholder()
    {
        const int cells = 25;
        const double size = 176, inset = 14, cell = (size - inset * 2) / cells;
        var canvas = new Canvas { Width = size, Height = size, IsHitTestVisible = false };
        var color = Brush(0xD6D6D1);
        void Rect(double x, double y, double w, double h, double r = 0, bool stroke = false)
        {
            var shape = new Rectangle { Width = w, Height = h, RadiusX = r, RadiusY = r };
            if (stroke) { shape.Stroke = color; shape.StrokeThickness = cell; } else shape.Fill = color;
            Canvas.SetLeft(shape, x);
            Canvas.SetTop(shape, y);
            canvas.Children.Add(shape);
        }
        void Finder(int col, int row)
        {
            double x = inset + col * cell, y = inset + row * cell;
            Rect(x, y, cell * 7, cell * 7, cell * 1.2, stroke: true);
            Rect(x + cell * 2, y + cell * 2, cell * 3, cell * 3, cell * 0.6);
        }
        Finder(0, 0); Finder(cells - 7, 0); Finder(0, cells - 7);
        uint seed = 20261027;
        for (var row = 0; row < cells; row++)
            for (var col = 0; col < cells; col++)
            {
                seed = unchecked(seed * 1103515245 + 12345);
                var inFinder = (row < 8 && col < 8) || (row < 8 && col >= cells - 8) || (row >= cells - 8 && col < 8);
                if (inFinder || (seed >> 16) % 5 > 1) continue;
                Rect(inset + col * cell, inset + row * cell, cell, cell);
            }
        return canvas;
    }

    // MARK: 开发环境邮箱密码（稿 E）

    StackPanel PasswordColumn()
    {
        var submit = new V3Button(_submitting ? "登录中…" : "登录", Submit, V3Button.Kind.Dark, fill: true, icon: _submitting ? null : "arrow.right") { Enabled = CanSubmit };
        var email = new V3TextInput("邮箱", "you@example.com", _email, submit: Submit);
        var password = new PasswordBox { PlaceholderText = "至少 8 位", Password = _password, Height = 32, MinHeight = 0, FontSize = 13, CornerRadius = new CornerRadius(4), BorderBrush = Brush(Cl), Padding = new Thickness(12, 6, 12, 0) };
        Quiet(password.Resources);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(password, "密码");
        email.Box.TextChanged += (_, _) => { _email = email.Text; submit.Enabled = CanSubmit; };
        password.PasswordChanged += (_, _) => { _password = password.Password; submit.Enabled = CanSubmit; };
        password.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) Submit(); };
        var column = VStack(0,
            V3Chip.Make("仅开发环境", Sub, Field, 20, 11).Align(HorizontalAlignment.Center),
            Label("登录 DrawOffer", 26, Txt, Semibold).Align(HorizontalAlignment.Center).Top(12),
            Sans("开发环境支持使用邮箱和密码进入工作台。", 13, Sub).Align(HorizontalAlignment.Center).Top(8),
            VStack(16, email, VStack(8, Sans("密码", 13, Sub, Medium), password)).Frame(width: 320).Top(28),
            Agreement().Top(20));
        if ((_message ?? App.Session.ErrorMessage) is { } error)
            column.Children.Add(Sans(error, 12, Red).Wrap().Also(x => { x.TextAlignment = TextAlignment.Center; x.MaxWidth = 320; }).Align(HorizontalAlignment.Center).Top(12));
        column.Children.Add(submit.Frame(width: 320).Top(20));
        return column;
    }

    bool CanSubmit => !_submitting && _agreed && _email.Trim().Length > 0 && _password.Length > 0;

    async void Submit()
    {
        if (!CanSubmit) return;
        _submitting = true;
        _message = null;
        Render();
        await App.Session.SignInCommand.ExecuteAsync((_email.Trim(), _password));
        _submitting = false;
        if (App.Session.Phase == SessionViewModel.SessionPhase.SignedIn) _password = "";
        Render();
    }
}
