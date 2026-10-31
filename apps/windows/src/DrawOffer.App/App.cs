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
            var origin = Environment.GetEnvironmentVariable("DRAWOFFER_API_ORIGIN") ?? throw new InvalidOperationException("API origin missing");
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

/// <summary>主窗口：Mica 背景、内容延伸进标题栏（40 高拖动区），1280×820；与 Mac 一样窗口里只有工作区外壳。</summary>
public sealed class MainWindow : Window
{
    public MainWindow()
    {
        Title = "DrawOffer";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var titleBar = new Grid { Background = new SolidColorBrush(DesignSystem.V3.Hex(0xF1F1EF)) };
        root.Children.Add(titleBar);
        var shell = new WorkspaceShell();
        Grid.SetRow(shell, 1);
        root.Children.Add(shell);
        Content = root;
        SetTitleBar(titleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 820));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "DrawOffer.ico"));
        Activated += (_, e) => { if (e.WindowActivationState != WindowActivationState.Deactivated) shell.OnActivated(); };
    }
}
