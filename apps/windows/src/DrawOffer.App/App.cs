using System.Security.Principal;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Session;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Win32;

namespace DrawOffer.App;

/// <summary>
/// 应用入口（纯 C#，不使用 App.xaml）：单实例、注册 `drawoffer://` 协议、浏览器登录回调转给已运行的实例。
/// 对应 Mac `DrawOfferApp.swift` 的 `onOpenURL` 与实例租约。
/// </summary>
public partial class App : Application
{
    public static SessionViewModel Session { get; private set; } = null!;
    internal static Window? NativeWindow => (Current as App)?._window;
    /// <summary>文件选择器需要窗口句柄初始化。</summary>
    internal static Window MainWindow => NativeWindow ?? throw new InvalidOperationException("窗口尚未创建");
    DesktopTransport? _transport;
    Window? _window;
    Mutex? _instance;

    [STAThread]
    static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        // 已有实例时把激活参数（协议回调）转给它后退出
        var key = $"DrawOffer.Desktop.{WindowsIdentity.GetCurrent().User?.Value}";
        var main = AppInstance.FindOrRegisterForKey(key);
        if (!main.IsCurrent)
        {
            main.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()).AsTask().Wait();
            return;
        }
        Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
    }

    public App()
    {
        // 代替 App.xaml 里的 <XamlControlsResources/>：加载 WinUI 控件的默认样式
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        AppInstance.GetCurrent().Activated += (_, args) => _window?.DispatcherQueue.TryEnqueue(() => OnActivated(args));
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            // 默认连线上 www.drawoffer.com；开发环境用 DRAWOFFER_API_ORIGIN 覆盖（与 Mac 一致）
            var origin = Environment.GetEnvironmentVariable("DRAWOFFER_API_ORIGIN") is { Length: > 0 } value ? value : "https://www.drawoffer.com";
            _instance = new Mutex(false, $"Local\\DrawOffer.Desktop.{WindowsIdentity.GetCurrent().User?.Value}");
            var owned = false;
            try { owned = _instance.WaitOne(0); }
            catch (AbandonedMutexException) { owned = true; }
            if (!owned) { ShowStartupError("DrawOffer 已在运行，请使用已打开的窗口。"); return; }
            _transport = new DesktopTransport(new Uri(origin), Environment.GetEnvironmentVariable("DRAWOFFER_ALLOW_LOCAL_HTTP") == "1");
            Session = new(new HttpApiClient(new SessionCoordinator(_transport, new CredentialLockerTokenStore())));
        }
        catch (Exception)
        {
            ShowStartupError("API 地址未配置或无效。请设置 DRAWOFFER_API_ORIGIN 后重新启动。");
            return;
        }
        RegisterProtocol();
        _window = new MainWindow();
        _window.Activate();
        await Session.RestoreAsync();
        OnActivated(AppInstance.GetCurrent().GetActivatedEventArgs());
    }

    /// <summary>协议激活：只接受 `drawoffer://auth/callback`，其余忽略。</summary>
    async void OnActivated(AppActivationArguments args)
    {
        Uri? callback = args.Kind switch
        {
            ExtendedActivationKind.Protocol when args.Data is Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs protocol => protocol.Uri,
            ExtendedActivationKind.Launch when args.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch => BrowserCallback.FromArguments(launch.Arguments.Split(' ', StringSplitOptions.RemoveEmptyEntries)),
            _ => null,
        };
        if (_window is null) return;
        _window.Activate();
        if (callback is not null && BrowserCallback.Parse(callback) is not null) await Session.CompleteBrowserLoginAsync(callback);
        WorkspaceShell.Current?.OnActivated();
    }

    /// <summary>未打包（unpackaged）应用在当前用户下注册 `drawoffer://`，指向本程序；不需要管理员权限。</summary>
    static void RegisterProtocol()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (exe is null) return;
            using var root = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{BrowserCallback.Scheme}");
            root.SetValue("", "URL:DrawOffer");
            root.SetValue("URL Protocol", "");
            using var command = root.CreateSubKey(@"shell\open\command");
            command.SetValue("", $"\"{exe}\" \"%1\"");
        }
        catch { }
    }

    void ShowStartupError(string message)
    {
        _window = new Window { Content = new TextBlock { Text = message, Margin = new Thickness(32), TextWrapping = TextWrapping.Wrap } };
        _window.Activate();
    }
}

/// <summary>
/// 主窗口（Windows 稿 00 页规则）：Mica 背景 + ExtendsContentIntoTitleBar，窗口内容铺到顶边；标题栏高 48 与内容合一，
/// 右上角系统最小化/最大化/关闭（46×32，透明底、墨色前景，悬停 #F4F4F2，关闭悬停红底由系统绘制）。
/// 拖动区由工作区外壳按页面指定（<see cref="SetDragRegion"/>）。默认 1440×900，最小 1100×700。
/// </summary>
public sealed class MainWindow : Window
{
    public MainWindow()
    {
        Title = "DrawOffer";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = Microsoft.UI.Windowing.TitleBarHeightOption.Tall;
        var bar = AppWindow.TitleBar;
        bar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        bar.ButtonForegroundColor = DesignSystem.V3.Txt;
        bar.ButtonInactiveForegroundColor = DesignSystem.V3.Fnt;
        bar.ButtonHoverBackgroundColor = DesignSystem.V3.Field;
        bar.ButtonHoverForegroundColor = DesignSystem.V3.Txt;
        bar.ButtonPressedBackgroundColor = DesignSystem.V3.Hl;
        bar.ButtonPressedForegroundColor = DesignSystem.V3.Txt;
        var shell = new WorkspaceShell();
        Content = shell;
        var scale = (Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(1440 * scale), (int)(900 * scale)));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 1100;
            presenter.PreferredMinimumHeight = 700;
        }
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "DrawOffer.ico"));
        Activated += (_, e) => { if (e.WindowActivationState != WindowActivationState.Deactivated) shell.OnActivated(); };
    }

    /// <summary>设置标题栏拖动区；null 时不设（登录页等整窗页面由系统按标题栏高度处理）。</summary>
    public void SetDragRegion(FrameworkElement? region) => SetTitleBar(region);

    /// <summary>
    /// 自绘标题栏（编辑器等整窗页面）里可点的控件：把它们的范围设为穿透区，其余标题栏高度内仍可拖动窗口。传空清除。
    /// </summary>
    public void SetPassthrough(IEnumerable<FrameworkElement> elements)
    {
        var rects = new List<Windows.Graphics.RectInt32>();
        foreach (var element in elements)
        {
            if (element.XamlRoot is not { } root || element.ActualWidth <= 0 || element.Visibility != Visibility.Visible) continue;
            var scale = root.RasterizationScale;
            var bounds = element.TransformToVisual(null).TransformBounds(new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            rects.Add(new Windows.Graphics.RectInt32((int)Math.Round(bounds.X * scale), (int)Math.Round(bounds.Y * scale),
                (int)Math.Round(bounds.Width * scale), (int)Math.Round(bounds.Height * scale)));
        }
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, [.. rects]);
    }
}
