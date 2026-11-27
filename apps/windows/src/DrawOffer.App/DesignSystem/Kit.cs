using DrawOffer.Core.Api;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>系统文件选择（FileOpenPicker 需要窗口句柄初始化）与剪贴板。</summary>
public static class Files
{
    public static async Task<StorageFile?> PickAsync(params string[] extensions)
    {
        if (App.NativeWindow is not { } window) return null;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var extension in extensions.Length > 0 ? extensions : ["*"]) picker.FileTypeFilter.Add(extension == "*" ? "*" : "." + extension.TrimStart('.'));
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        return await picker.PickSingleFileAsync();
    }

    public static async Task<byte[]> ReadAsync(StorageFile file)
    {
        var buffer = await FileIO.ReadBufferAsync(file);
        var bytes = new byte[buffer.Length];
        using var reader = Windows.Storage.Streams.DataReader.FromBuffer(buffer);
        reader.ReadBytes(bytes);
        return bytes;
    }

    public static bool Copy(string text)
    {
        try
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(text);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            return true;
        }
        catch { return false; }
    }

    public static async Task<BitmapImage?> BitmapAsync(byte[] data)
    {
        try
        {
            var bitmap = new BitmapImage();
            using var stream = new MemoryStream(data).AsRandomAccessStream();
            await bitmap.SetSourceAsync(stream);
            return bitmap;
        }
        catch { return null; }
    }
}

/// <summary>接口错误 → 用户能看懂的一句话（Mac `AccountRequest.errorMessage` 等的共用版本）。</summary>
public static class ErrorText
{
    static readonly Dictionary<string, string> Known = new()
    {
        ["INVALID_NICKNAME"] = "昵称需要 1–50 个字符。",
        ["INVALID_CONTACT_EMAIL"] = "请输入有效的邮箱地址。",
        ["INVALID_ACCOUNT_PREFERENCES"] = "偏好设置无效，请刷新后重试。",
        ["USER_PROFILE_VERSION_CONFLICT"] = "求职资料已在其他设备更新，已为你读取最新版本，请确认后再保存。",
        ["INVALID_IMAGE"] = "只支持 PNG 或 JPEG 图片。",
        ["IMAGE_TOO_LARGE"] = "图片超过 10 MB，请换一张。",
        ["ASSET_UPLOAD_FAILED"] = "上传失败，请稍后重试。",
        ["DESKTOP_ROUTE_FORBIDDEN"] = "桌面端不提供此操作。",
        ["INSUFFICIENT_CREDITS"] = "积分不足，充值或升级后再试。",
    };

    public static string From(Exception error, string fallback, IReadOnlyDictionary<string, string>? extra = null)
    {
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) return "登录已失效，请重新登录。";
        if (error is not ApiException api) return fallback;
        if (extra is not null && extra.TryGetValue(api.Code, out var custom)) return custom;
        return Known.TryGetValue(api.Code, out var known) ? known : fallback;
    }

    public static bool Is(Exception error, string code) => error is ApiException api && api.Code == code;
}

/// <summary>
/// 顶部提示（`.v3-toast`）：内容区顶部居中、最小 320 宽、圆角 8 的白卡，3 秒后收起。
/// 由工作区外壳提供宿主（<see cref="Host"/>）；没有宿主时不显示。
/// </summary>
public static class V3Toast
{
    public enum Kind { Success, Error, Warn }
    public static Panel? Host { get; set; }
    static int _generation;

    public static void Show(string title, Kind kind = Kind.Success, string? message = null)
    {
        if (Host is not { } host) return;
        var generation = ++_generation;
        var icon = Icon(kind == Kind.Success ? "checkmark" : "exclamationmark.circle", 13, kind switch { Kind.Error => Red, Kind.Warn => Orange, _ => Green });
        var card = new Border
        {
            MinWidth = 320, Padding = new Thickness(16, 12, 16, 12), CornerRadius = new CornerRadius(8), Background = Brush(White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 16, 0, 0),
            Child = Columns(10, (Auto, icon.Align(v: VerticalAlignment.Top).Pad(0, 2, 0, 0)),
                (Star(), VStack(4, Label(title, 14, Txt, Medium), message is null ? null : Sans(message, 12, Sub).Wrap()))),
        }.Elevate(16);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetLiveSetting(card, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        host.Children.Clear();
        host.Children.Add(card);
        DispatcherTimerLike? timer = null;
        timer = new DispatcherTimerLike(host.DispatcherQueue, TimeSpan.FromSeconds(3), () =>
        {
            timer?.Stop();
            if (generation == _generation) host.Children.Clear();
        }, false);
    }
}

/// <summary>圆形头像：有图时裁成圆，没有时墨黑底白色首字。</summary>
public static class AvatarCircle
{
    public static FrameworkElement Make(ImageSource? image, string initial, double size)
    {
        if (image is not null)
            return new Microsoft.UI.Xaml.Shapes.Ellipse { Width = size, Height = size, Fill = new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill } };
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = Brush(Txt),
            Child = Label(initial, size * 0.4, White, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
    }
}
