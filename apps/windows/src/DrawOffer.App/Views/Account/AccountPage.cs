using System.ComponentModel;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Account;

/// <summary>Mac AccountSection / AccountView：账号资料与独立求职资料页。</summary>
public sealed partial class AccountPage : Page
{
    readonly Grid _root = new();
    readonly CancellationTokenSource _life = new();
    JsonNode? _profile, _preferences;
    ImageSource? _avatar;
    string _account = "", _summary = "", _error = "";
    int _epoch, _toastGeneration;
    bool _disposed, _loading = true, _preferenceFailed, _savingPreference, _career;
    V3Overlay? _overlay;
    Border? _toast;
    string Account => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User?.Id ?? "" : "";
    string Stamp => _epoch + ":" + Account;
    JsonNode? User => _profile?["user"];
    string Initial => System.Globalization.StringInfo.GetNextTextElement(User.Text("nickname").Trim() is { Length: > 0 } name ? name : "我");
    public AccountPage()
    {
        Content = _root; Background = Brush(White);
        Loaded += async (_, _) => { _account = Account; App.Session.PropertyChanged += Changed; Render(); await Load(); };
        Unloaded += (_, _) => { _disposed = true; ++_epoch; _life.Cancel(); _overlay?.Close(); App.Session.PropertyChanged -= Changed; };
    }
    async void Changed(object? sender, PropertyChangedEventArgs args)
    {
        if (_account == Account) return;
        _account = Account; ++_epoch; _overlay?.Close(); _profile = _preferences = null; _avatar = null; _summary = _error = ""; _career = false; _loading = true; _savingPreference = false; Render(); await Load();
    }
    internal async Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null, Dictionary<string, string>? query = null)
    {
        var stamp = Stamp;
        try { var result = await App.Session.Api.CareerRequestAsync(path, method, query, body, _life.Token); if (_disposed || stamp != Stamp || Account.Length == 0) throw new OperationCanceledException(); return result; }
        catch { if (_disposed || stamp != Stamp || Account.Length == 0) throw new OperationCanceledException(); throw; }
    }
    async Task Load()
    {
        if (Account.Length == 0) { _loading = false; Render(); return; }
        var stamp = Stamp; _loading = true;
        var preferences = LoadPreferences(); var summary = LoadSummary();
        try { _profile = await Request("/api/account/profile"); ApplyUser(User); await LoadAvatar(); }
        catch (OperationCanceledException) { return; }
        catch { /* 加载失败时保留已取得的资料，由空态提供重试。 */ }
        if (stamp != Stamp || _disposed) return;
        _loading = false; await Task.WhenAll(preferences, summary); Render();
    }
    async Task LoadPreferences()
    {
        try { _preferences = await Request("/api/account/preferences"); _preferenceFailed = false; }
        catch (OperationCanceledException) { } catch { _preferenceFailed = true; }
    }
    async Task LoadSummary()
    {
        try { var value = await Request("/api/account/career-profile"); var source = value["experience_resume"].Text("title"); _summary = string.Join(" · ", new[] { value["personal"].Text("name"), source.Length > 0 ? $"经历读自《{source}》" : "还没有读取简历" }.Where(x => x.Length > 0)); }
        catch (OperationCanceledException) { } catch { _summary = ""; }
    }
    void ApplyUser(JsonNode? user)
    {
        if (user is null) return;
        if (_profile is JsonObject profile) profile["user"] = user.DeepClone();
        if (App.Session.User is { } current) App.Session.User = current with { Nickname = user.Text("nickname"), AvatarUrl = user.Text("avatar_url") };
    }
    async Task LoadAvatar()
    {
        var stamp = Stamp; var path = User.Text("avatar_url"); _avatar = null;
        try {
            if (path.StartsWith("/api/auth/default-avatar", StringComparison.Ordinal)) _avatar = new BitmapImage(new Uri("ms-appx:///Assets/Branding/default-avatar.png"));
            else if (path.Length > 0 && App.Session.Api is HttpApiClient client) {
                var bytes = await client.Coordinator.AccountAvatarAsync(path, _life.Token);
                if (stamp != Stamp || _disposed) return;
                using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream(); using (var writer = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
                stream.Seek(0); var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream); if (stamp == Stamp && !_disposed) _avatar = bitmap;
            }
        } catch { if (stamp == Stamp) _avatar = null; }
    }
    internal static TextBox Input(string value, string label, double height = 34) => new TextBox { Text = value, FontFamily = SansFamily, FontSize = 14, Height = height, MinHeight = 0, Padding = new Thickness(14, 4, 14, 4), CornerRadius = new(8), BorderBrush = Brush(Cl), Background = Brush(White), Foreground = Brush(Txt) }.Tip(label);
    internal static V3Button LinkButton(string title, Action action) => new(title, action, V3Button.Kind.Text) { TextSize = 12.5 };
    internal static Border Notes(params string[] lines) => Fill(Hex(0xF6F6F4), 10, child: VStack(8, lines.Select(line => Sans("•  " + line, 13).Wrap().LineHeight(19)).ToArray())).WithPadding(new Thickness(18, 12, 16, 12));
    internal static string Explain(Exception error, string fallback = "保存失败，请稍后重试。") => error is ApiException api ? api.Code switch {
        "INVALID_NICKNAME" => "昵称需要 1–50 个字符。", "INVALID_CONTACT_EMAIL" => "请输入有效的邮箱地址。", "INVALID_ACCOUNT_PREFERENCES" => "偏好设置无效，请刷新后重试。", "USER_PROFILE_VERSION_CONFLICT" => "资料在别处改过了，已刷新为最新内容，请再改一次。", "INVALID_IMAGE" => "只支持 PNG 或 JPEG 图片。", "IMAGE_TOO_LARGE" => "图片超过 10 MB，请换一张。", "ASSET_UPLOAD_FAILED" => "头像上传失败，请稍后重试。", "AUTOFILL_ID_CONSENT_REQUIRED" => "保存证件号码前需要你单独同意。", "AUTOFILL_ID_STORAGE_UNAVAILABLE" => "证件号码暂时无法保存，请稍后再试。", "RESUME_NOT_FOUND" => "这份简历不存在或已删除。", _ => fallback } : fallback;
    void Render()
    {
        if (_disposed) return;
        _root.Children.Clear();
        if (_toast is not null) { _root.Children.Add(_toast); Canvas.SetZIndex(_toast,10); }
        if (_career) { _root.Children.Add(new CareerProfileView(this, () => { _career = false; Render(); _ = RefreshSummary(); })); return; }
        var mode = _profile?["capabilities"].Text("auth_mode");
        var eyebrow = "ACCOUNT" + (mode == "password" ? " · " + User.Text("email") : mode == "wechat" ? " · 微信登录" : "");
        var body = VStack(0, Sans(eyebrow, 12, Fnt, Medium).Frame(height:18), Serif("账号", 28).Frame(height:36).Top(9), Sans("管理个人资料、登录安全与偏好设置。", 14, Sub).Frame(height:22).Top(6));
        if (Account.Length == 0) body.Children.Add(new V3Button("登录后管理账号", () => _ = Shell.WorkspaceShell.Current.RequestLoginAsync()).Top(40));
        else if (_profile is null) body.Children.Add(VStack(12, Sans(_loading ? "正在加载个人资料…" : "暂时无法读取个人资料", 18), !_loading ? new V3Button("重新加载", () => _ = Load()) : null).Top(_loading ? 80 : 40));
        else {
            if (_error.Length > 0) body.Children.Add(Fill(Hex(0xFDF5F5), 10, child: Spread(Sans("保存失败  " + _error, 14).Wrap(), LinkButton("×", () => { _error = ""; Render(); }))).WithPadding(new(16,12,12,12)).Top(14));
            var avatar = Avatar(_avatar, Initial, 56); avatar.PointerReleased += (_, _) => { if (_avatar is not null) _overlay = V3Overlay.Show(XamlRoot, close => V3Dialog.Frame(Layer(new Image { Source = _avatar, Width = 420, Stretch = Stretch.Uniform }, V3Dialog.CloseButton(close).Align(HorizontalAlignment.Right, VerticalAlignment.Top)), 420)); };
            var registered = DateTimeOffset.TryParse(User.Text("registered_at"), out var date) ? date.ToBeijing().ToString("yyyy年M月d日") : "—";
            body.Children.Add(Card(Spread(HStack(16, avatar, VStack(8, Sans(User.Text("nickname"),16,Txt,Semibold).Frame(height:24), Sans("注册于 " + registered,12,Fnt).Frame(height:18))), new V3Button("编辑资料", EditProfile, width:96)),14,new Thickness(23,0,23,0)).Frame(height:92).Top(28));
            var security = VStack(0);
            if (mode == "password") security.Children.Add(Row("登录邮箱", User.Text("email"), null));
            if (mode == "wechat") security.Children.Add(Row("登录方式", "微信登录", null));
            security.Children.Add(Row("联系邮箱", User.Text("contact_email") is { Length: > 0 } email ? email : "未设置", LinkButton(User.Text("contact_email").Length == 0 ? "设置 ›" : "修改 ›", ContactEmail)));
            body.Children.Add(Section("账号与安全", "管理登录方式与联系信息。", security));
            body.Children.Add(Section("求职资料", "网申插件和 AI 都只用这一份，不会改动简历。", Row("求职资料", _summary.Length > 0 ? _summary : "基本信息、证件、求职意向和经历", LinkButton("查看与编辑 ›", () => { _career = true; Render(); }))));
            var language = new ComboBox { Width = 160, Height = 32, MinHeight = 0, FontFamily = SansFamily, FontSize = 14, ItemsSource = new[] { "简体中文", "English" }, SelectedIndex = _preferences.Text("locale") == "en-US" ? 1 : 0, IsEnabled = _preferences is not null && !_savingPreference };
            language.SelectionChanged += async (_, _) => { if (!_savingPreference) await SavePreference(language.SelectedIndex == 1 ? "en-US" : "zh-CN"); };
            var preference = VStack(0); if (_preferenceFailed) preference.Children.Add(HStack(8, Sans("偏好读取失败，请重新加载后重试。",14,Sub), LinkButton("重试", () => _ = RetryPreferences())).Pad(19,14,19,0)); preference.Children.Add(Row("界面语言", "", language));
            body.Children.Add(Section("偏好", "界面显示偏好。", preference));
            body.Children.Add(Section("退出与注销", "注销后个人数据会被永久清理，无法恢复。", Row("退出登录", _profile["current_session"].Text("device_label"), new V3Button("退出", Logout, height:28,width:72,small:true))).Pad(0,32,0,20));
        }
        var container = new Border { Child = body, MaxWidth = 1056, HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(24,51,24,64) };
        _root.Children.Add(new ScrollViewer { Content = container, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
    }
    async Task RefreshSummary() { await LoadSummary(); if (!_career) Render(); }
    async Task RetryPreferences() { await LoadPreferences(); Render(); }
    async Task SavePreference(string locale)
    {
        if (_savingPreference) return; var stamp = Stamp; _savingPreference = true;
        try { _preferences = await Request("/api/account/preferences", "PATCH", new JsonObject { ["locale"] = locale }); Toast("偏好已保存"); }
        catch (OperationCanceledException) { return; } catch (Exception ex) { Toast(Explain(ex,"偏好保存失败，请重试。"), true); }
        finally { if (stamp == Stamp) _savingPreference = false; } Render();
    }
    static Border Row(string label, string value, UIElement? action) => new() { Child = Columns(0, (Px(148), Sans(label,14,Txt,Medium)), (Star(), Sans(value,14,Sub).Wrap().LineHeight(22).Pad(0,0,12,0)), (Auto, action ?? new Grid())), Padding = new(19,14,19,14), MinHeight = 56, BorderBrush = Brush(Line), BorderThickness = new(0,1,0,0) };
    static FrameworkElement Section(string title, string description, UIElement content) => Columns(0, (Px(228), VStack(9, Sans(title,16,Txt,Semibold).Frame(height:24), Sans(description,14,Fnt).Wrap().LineHeight(22)).Pad(0,4,28,0)), (Star(), Card(content,12))).Top(32);
    internal static Border Avatar(ImageSource? image, string initial, double size) => Fill(Txt,size/2,size,size,image is null ? Label(initial,size*.4,White,Medium).Align(HorizontalAlignment.Center,VerticalAlignment.Center) : new EllipseImage(image,size));
    internal void Toast(string message, bool error = false)
    {
        if (_disposed) return; if (_toast is not null) _root.Children.Remove(_toast); var generation = ++_toastGeneration;
        _toast = Card(HStack(10, Icon(error ? "exclamationmark.circle" : "checkmark",13,error?Red:Green), Sans(message,14,Txt,Medium)),12,new Thickness(16,14,16,14)); _toast.MinWidth=320; _toast.HorizontalAlignment=HorizontalAlignment.Center; _toast.VerticalAlignment=VerticalAlignment.Top; _toast.Margin=new(0,28,0,0); _toast.Elevate(12); _root.Children.Add(_toast); Canvas.SetZIndex(_toast,10);
        _ = Hide(); async Task Hide() { try { await Task.Delay(3000,_life.Token); if (generation == _toastGeneration && _toast is not null) { _root.Children.Remove(_toast); _toast=null; } } catch(OperationCanceledException){} }
    }
    sealed class EllipseImage : Grid
    {
        public EllipseImage(ImageSource image,double size) { Width=Height=size; Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width=size, Height=size, Fill=new ImageBrush { ImageSource=image, Stretch=Stretch.UniformToFill } }); }
    }
}
internal static class AccountBorderExtensions { internal static Border WithPadding(this Border border, Thickness padding) { border.Padding=padding; return border; } }
