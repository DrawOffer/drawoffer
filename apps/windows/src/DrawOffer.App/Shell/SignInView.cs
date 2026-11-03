using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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

    public static void OpenEditor(string resumeId)
    {
        if (resumeId.All(char.IsAsciiDigit)) Open($"/resumes/{resumeId}/edit");
    }
}

/// <summary>
/// 登录入口，对应 Mac `SignInView`：不在客户端内填写账号，打开浏览器登录并授权，授权码经 `drawoffer://auth/callback` 回到客户端。
/// </summary>
public sealed class SignInView : Grid
{
    readonly TextBlock _hint = Sans("", 14, Sub).Wrap();
    readonly TextBlock _error = Sans("", 14, Red).Wrap();
    readonly StackPanel _actions = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center };
    string? _message;
    bool _opening;

    public SignInView()
    {
        Background = Brush(0xFCFCFC); // Tokens.Color.background
        _hint.TextAlignment = TextAlignment.Center;
        _hint.MaxWidth = 360;
        _error.TextAlignment = TextAlignment.Center;
        var stack = VStack(16, Serif("在浏览器中登录 DrawOffer", 20).Align(HorizontalAlignment.Center), _hint, _error, _actions);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        stack.Padding = new Thickness(32);
        Children.Add(stack);
        App.Session.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(Render);
        Render();
    }

    void Render()
    {
        var pending = App.Session.BrowserLoginPending;
        _hint.Text = _message ?? (pending ? "已在浏览器打开登录页。登录后点击“授权并打开客户端”，会自动回到这里。" : "点击下方按钮，在浏览器完成登录后会自动回到客户端。");
        _error.Text = App.Session.ErrorMessage ?? "";
        _error.Visibility = App.Session.ErrorMessage is null ? Visibility.Collapsed : Visibility.Visible;
        _actions.Children.Clear();
        if (App.Session.Phase == SessionViewModel.SessionPhase.Restoring)
            _actions.Children.Add(new V3Button("重试恢复登录", () => _ = App.Session.RestoreAsync()).Align(HorizontalAlignment.Center));
        _actions.Children.Add(new V3Button(pending ? "重新打开浏览器登录" : "在浏览器中登录", Open, V3Button.Kind.Dark, height: 36) { Enabled = !_opening }.Align(HorizontalAlignment.Center));
    }

    async void Open()
    {
        _opening = true;
        _message = null;
        Render();
        try
        {
            var uri = await App.Session.BeginBrowserLoginAsync(DesktopClient.Version);
            await Windows.System.Launcher.LaunchUriAsync(uri);
        }
        catch { _message = "暂时无法打开登录页，请检查网络后重试。"; }
        _opening = false;
        Render();
    }
}

public static class DesktopClient
{
    public static string Version => typeof(DesktopClient).Assembly.GetName().Version is { } version ? $"{version.Major}.{version.Minor}.{version.Build}" : "0.1.0";
}
