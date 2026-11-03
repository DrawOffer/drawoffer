using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Resumes;

/// <summary>弹窗共用：401 时上报登录失效。</summary>
static class SheetErrors
{
    public static bool Unauthorized(Exception error)
    {
        if (error is not ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) return false;
        App.Session.ReportAuthenticationFailure();
        return true;
    }

    public static bool Server(Exception error, out int status, out string code)
    {
        if (error is ApiException api && api.Status != System.Net.HttpStatusCode.Unauthorized) { status = (int)api.Status; code = api.Code; return true; }
        status = 0; code = "";
        return false;
    }
}

/// <summary>
/// 重命名（Web `RenameResumeDialog`）与复制为新简历，对应 Mac `ResumeTitleSheet`。重命名只改列表标题，不写入正文；
/// 复制携带固定的 `client_request_id`，结果不确定时重试不会多复制一份。
/// </summary>
public static class ResumeTitleSheet
{
    public enum Mode { Rename, Copy }

    public static void Show(XamlRoot root, Mode mode, ResumeSummary resume, Action<string> done)
    {
        V3Overlay? overlay = null;
        var busy = false;
        var requestId = Guid.NewGuid().ToString("D").ToLowerInvariant();
        var box = new TextBox { Text = mode == Mode.Rename ? resume.Title : $"{resume.Title} 副本", PlaceholderText = "简历名称", FontSize = 13, FontFamily = SansFamily };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "简历名称");
        var error = Sans("", 12.5, Red).Wrap();
        error.Visibility = Visibility.Collapsed;
        V3Button? cancel = null, submit = null;
        string Normalized() => box.Text.Trim();
        void Paint()
        {
            var name = Normalized();
            submit!.Title = busy ? "正在保存…" : mode == Mode.Rename ? "保存" : "确认复制";
            submit.Enabled = !busy && name.Length > 0 && !(mode == Mode.Rename && name == resume.Title);
            cancel!.Enabled = !busy;
        }
        void Fail(string? text) { error.Text = text ?? ""; error.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible; }
        async void Submit()
        {
            var name = Normalized();
            if (busy || name.Length == 0) return;
            if (name.Length > 255 || name.Any(c => c is '\n' or '\r')) { Fail("名称无效，请输入 1–255 个字符且不含换行。"); return; }
            if (mode == Mode.Rename && name == resume.Title) { overlay?.Close(); return; }
            busy = true; Fail(null); Paint();
            try
            {
                if (mode == Mode.Rename)
                    await App.Session.Api.CareerRequestAsync($"/api/resumes/{resume.Id}", "PUT", body: new JsonObject { ["title"] = name, ["base_lock_version"] = resume.LockVersion });
                else
                    await App.Session.Api.CareerRequestAsync($"/api/resumes/{resume.Id}/copy", "POST",
                        body: new JsonObject { ["title"] = name, ["base_lock_version"] = resume.LockVersion, ["client_request_id"] = requestId });
                overlay?.Close();
                done(name);
            }
            catch (Exception failure)
            {
                SheetErrors.Unauthorized(failure);
                var fallback = mode == Mode.Rename ? "保存名称失败，请刷新列表后重试。" : "复制失败，请检查名称、简历数量或刷新后重试。";
                if (failure is ApiException) Fail(ResumeRequest.ErrorMessage(failure, fallback));
                else Fail(mode == Mode.Copy ? "网络中断，结果尚未确认。可以直接重试，不会重复复制。" : "网络中断，结果尚未确认，请重试。");
            }
            finally { busy = false; Paint(); }
        }
        box.TextChanged += (_, _) => { if (mode == Mode.Copy) requestId = Guid.NewGuid().ToString("D").ToLowerInvariant(); Paint(); };
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Submit(); } };
        overlay = V3Overlay.Show(root, close =>
        {
            cancel = new V3Button("取消", close);
            submit = new V3Button("", Submit, V3Button.Kind.Dark);
            Paint();
            var body = VStack(14,
                Serif(mode == Mode.Rename ? "重命名简历" : "复制为新简历", 20),
                Sans(mode == Mode.Rename ? "只修改列表中用于识别的名称，不会改动简历正文。" : $"基于「{resume.Title}」的当前版本复制一份，原简历不受影响。", 13, Sub).Wrap(),
                VStack(6, Sans("简历名称", 12, Sub, Medium), box),
                error,
                HStack(10, cancel, submit).Align(HorizontalAlignment.Right));
            body.Padding = new Thickness(24);
            return V3Dialog.Frame(body, 440);
        }, dismissible: true);
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
    }
}

/// <summary>
/// 分享简历（Web `features/home/SharePanel.tsx`），对应 Mac `ResumeShareSheet`：生成只读链接，设置谁可以查看、有效期与是否允许下载 PDF，
/// 支持复制、重新生成和删除链接。链接为 `{站点 origin}/share/{token}`。
/// </summary>
public sealed class ResumeShareSheet : UserControl
{
    enum Expiry { Week, Month, Forever }
    static string Title(Expiry value) => value switch { Expiry.Week => "7 天", Expiry.Month => "30 天", _ => "永久" };
    static DateTimeOffset? Date(Expiry value) => value switch
    {
        Expiry.Week => DateTimeOffset.UtcNow.AddSeconds(7 * 86_400),
        Expiry.Month => DateTimeOffset.UtcNow.AddSeconds(30 * 86_400),
        _ => null,
    };

    readonly ResumeSummary _resume;
    readonly Action _close;
    readonly StackPanel _root = new() { Spacing = 14, Padding = new Thickness(24), Width = 500 };
    ResumeShare? _share;
    bool _loaded, _loadFailed, _busy, _copied;
    string? _error;
    bool _createPublic = true, _createAllowDownload = true;
    Expiry _createExpiry = Expiry.Week;

    ResumeShareSheet(ResumeSummary resume, Action close)
    {
        _resume = resume;
        _close = close;
        Content = _root;
        Render();
        Loaded += async (_, _) => await LoadAsync();
    }

    public static void Show(XamlRoot root, ResumeSummary resume) =>
        V3Overlay.Show(root, close => V3Dialog.Frame(new ResumeShareSheet(resume, close), 500));

    Uri? Origin => (App.Session.Api as HttpApiClient)?.Coordinator.Origin;

    void Render()
    {
        _root.Children.Clear();
        _root.Children.Add(Serif("分享简历", 20));
        _root.Children.Add(Sans($"为「{_resume.Title}」生成只读链接，对方不用登录就能查看。", 13, Sub).Wrap());
        if (!_loaded && !_loadFailed)
            _root.Children.Add(HStack(8, new ProgressRing { Width = 16, Height = 16, IsActive = true }, Sans("正在读取分享状态…", 13))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center).Frame(height: 120));
        else if (_loadFailed)
            _root.Children.Add(Spread(Sans("分享状态读取失败，请稍后重试。", 13, Red), new V3Button("重试", () => _ = LoadAsync())).Frame(height: 80));
        else if (_share is { } share) _root.Children.Add(Existing(share));
        else _root.Children.Add(Creation());
        if (_error is { } error) _root.Children.Add(Sans(error, 12.5, Red).Wrap());
        var foot = HStack(10);
        if (_loaded && _share is null)
        {
            foot.Children.Add(new V3Button("取消", _close));
            foot.Children.Add(new V3Button(_busy ? "正在创建…" : "创建分享链接", () => _ = CreateAsync(), V3Button.Kind.Dark) { Enabled = !_busy });
        }
        else foot.Children.Add(new V3Button("完成", _close));
        foot.HorizontalAlignment = HorizontalAlignment.Right;
        _root.Children.Add(foot);
    }

    UIElement Creation()
    {
        var access = new V3Segmented<bool>([(true, "公开"), (false, "仅自己")], _createPublic, segmentWidth: (150 - 6) / 2.0).Tip("访问权限");
        access.Changed += value => { _createPublic = value; Render(); };
        var expiry = new V3Segmented<Expiry>(Enum.GetValues<Expiry>().Select(x => (x, Title(x))), _createExpiry, segmentWidth: (190 - 6) / 3.0).Tip("有效期");
        expiry.Changed += value => _createExpiry = value;
        var download = new ToggleSwitch { IsOn = _createAllowDownload, OnContent = "", OffContent = "", MinWidth = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(download, "允许下载 PDF");
        download.Toggled += (_, _) => { _createAllowDownload = download.IsOn; Render(); };
        var panel = VStack(12,
            Row("谁可以查看", _createPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开", access),
            Row("链接有效期", "到期后链接自动失效，可以重新生成", expiry),
            Row("允许下载 PDF", _createAllowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载", download));
        panel.IsHitTestVisible = !_busy;
        return panel;
    }

    UIElement Existing(ResumeShare share)
    {
        var expired = share.IsExpired();
        var link = Origin is { } origin ? share.Url(origin).AbsoluteUri : "";
        var linkText = Sans(expired ? "该分享链接已失效，访客将无法继续访问简历" : link, 12.5, expired ? Fnt : Txt);
        linkText.IsTextSelectionEnabled = true;
        var copy = new V3Button(expired ? "不可复制" : _copied ? "已复制" : "复制链接", () => Copy(link)) { Enabled = !expired && link.Length > 0 };
        var linkRow = Card(Spread(linkText, copy, 8), 8, new Thickness(12), Field, Clear);
        var status = HStack(6,
            new Ellipse { Width = 6, Height = 6, Fill = Brush(expired ? Red : Green) },
            Sans(expired ? "链接已过期" : "链接可用", 12, Txt, Medium),
            Sans("· " + ExpiryLabel(share), 12, Fnt));
        var access = new V3Segmented<bool>([(true, "公开"), (false, "仅自己")], share.IsPublic, segmentWidth: (150 - 6) / 2.0).Tip("访问权限");
        access.Changed += value => _ = UpdateAsync(new JsonObject { ["visibility"] = value ? "public" : "private" });
        V3Button adjust = null!;
        adjust = new V3Button("调整为…", () =>
        {
            var menu = new MenuFlyout();
            foreach (var option in Enum.GetValues<Expiry>())
            {
                var item = new MenuFlyoutItem { Text = Title(option) };
                item.Click += (_, _) => _ = UpdateAsync(new JsonObject { ["expires_at"] = ResumeShare.Encode(Date(option)) });
                menu.Items.Add(item);
            }
            menu.ShowAt(adjust);
        });
        var download = new ToggleSwitch { IsOn = share.AllowDownload, OnContent = "", OffContent = "", MinWidth = 0 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(download, "允许下载 PDF");
        download.Toggled += (_, _) => _ = UpdateAsync(new JsonObject { ["allow_download"] = download.IsOn });
        var regenerate = HStack(4, Icon("arrow.clockwise", 12, Link), Sans("重新生成链接", 12.5, Link)).OnTap(() => _ = ConfirmAsync(
            "重新生成分享链接？", $"重新生成后旧链接将立即失效，已转发的旧地址无法再访问。「{_resume.Title}」的可见性与下载权限会保留。", "确认重新生成", RegenerateAsync), "重新生成链接");
        var delete = Sans("删除链接", 12.5, Red).OnTap(() => _ = ConfirmAsync(
            "删除分享链接？", $"删除后旧地址将显示「分享链接已失效」，之后可重新创建。「{_resume.Title}」本身不受影响。", "确认删除", DeleteAsync), "删除链接");
        var panel = VStack(12, linkRow, status,
            Row("谁可以查看", share.IsPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开", access),
            Row("链接有效期", "到期后链接自动失效，可以重新生成", adjust),
            Row("允许下载 PDF", share.AllowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载", download),
            HStack(16, regenerate, delete));
        panel.IsHitTestVisible = !_busy;
        return panel;
    }

    static Grid Row(string title, string hint, UIElement control) =>
        Spread(VStack(2, Sans(title, 13, Txt, Medium), Sans(hint, 11.5, Fnt)), control, 12);

    static string ExpiryLabel(ResumeShare share)
    {
        if (share.ExpiresAt is not { } expires) return "永久有效";
        var label = expires.ToLocalTime().ToString("yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture);
        return share.IsExpired() ? $"已于 {label} 过期" : $"有效至 {label}";
    }

    async void Copy(string link)
    {
        try
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(link);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            _copied = true; Render();
            await Task.Delay(2000);
            _copied = false; Render();
        }
        catch (Exception) { _error = "复制失败，请手动复制链接。"; Render(); }
    }

    async Task ConfirmAsync(string title, string message, string action, Func<Task> run)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = message, PrimaryButtonText = action, CloseButtonText = "取消" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await run();
    }

    string Path => $"/api/resumes/{_resume.Id}/share";

    async Task LoadAsync()
    {
        _loadFailed = false; _error = null; Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync(Path);
            _share = ResumeShare.From(result["share"]); _loaded = true;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { SheetErrors.Unauthorized(error); _loadFailed = true; }
        Render();
    }

    async Task RunAsync(string method, JsonNode? body, string failure)
    {
        if (_busy) return;
        _busy = true; _error = null; Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync(Path, method, body: body);
            _share = method == "DELETE" ? null : ResumeShare.From(result["share"]);
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            SheetErrors.Unauthorized(error);
            _error = ResumeRequest.ErrorMessage(error, failure);
            if (error is ApiException { Status: System.Net.HttpStatusCode.NotFound, Code: "SHARE_LINK_UNAVAILABLE" }) _share = null;
        }
        finally { _busy = false; Render(); }
    }

    Task CreateAsync() => RunAsync("POST", new JsonObject
    {
        ["visibility"] = _createPublic ? "public" : "private",
        ["expires_at"] = ResumeShare.Encode(Date(_createExpiry)),
        ["allow_download"] = _createAllowDownload,
    }, "生成分享链接失败，请稍后重试。");

    Task RegenerateAsync()
    {
        if (_share is not { } share) return Task.CompletedTask;
        return RunAsync("POST", new JsonObject
        {
            ["visibility"] = share.IsPublic ? "public" : "private",
            ["expires_at"] = ResumeShare.Encode(share.RegeneratedExpiry()),
            ["allow_download"] = share.AllowDownload,
        }, "重新生成分享链接失败，请稍后重试。");
    }

    Task UpdateAsync(JsonObject fields) => RunAsync("PATCH", fields, "更新链接配置失败，请稍后重试。");
    Task DeleteAsync() => RunAsync("DELETE", null, "删除分享链接失败，请稍后重试。");
}

/// <summary>
/// 新建简历（Web `ResumeCreateDialog`，02.1a），对应 Mac `ResumeCreateSheet`：大预览 + 左右切换模板（← → 键）、简历名称，创建后直接进入编辑器。
/// 760 宽、高 min(900, 窗口 − 48)；标题 29 高，下方模板名与最多 3 个标签；点阵舞台撑满中间（外边距 20/31），
/// A4 纸面上下 24、左右 76 内缩，36 圆形翻页钮距边 20；名称区 20/32/24，输入框 44 高；页脚左侧「第 N / M 套」与提示，取消 80、提交 148。
/// </summary>
public sealed class ResumeCreateSheet : UserControl
{
    readonly string? _initialTemplateId;
    readonly Action<string> _created;
    readonly Action _close;
    List<ResumeTemplate> _templates = [];
    int _index;
    bool _loading = true, _loadFailed, _busy;
    string? _error;
    readonly TextBox _title = new()
    {
        PlaceholderText = "例如：后端工程师 · 字节跳动", FontSize = 13.5, FontFamily = SansFamily, Height = 44, MinHeight = 0, MaxLength = 255,
        Padding = new Thickness(14, 12, 14, 0), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1),
        Background = Brush(V3.White), Foreground = Brush(Txt), PlaceholderForeground = Brush(Fnt2),
    };
    readonly Grid _host = new();

    ResumeCreateSheet(string? initialTemplateId, Action<string> created, Action close)
    {
        _initialTemplateId = initialTemplateId;
        _created = created;
        _close = close;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_title, "简历名称");
        _title.TextChanged += (_, _) => { if (_error is not null) { _error = null; Render(); } };
        _title.GotFocus += (_, _) => PaintTitle();
        _title.LostFocus += (_, _) => PaintTitle();
        _title.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Submit(); } };
        Content = _host;
        // ← → 翻模板；焦点在名称输入框里时交给输入框移动光标
        KeyDown += (_, e) =>
        {
            if (_title.FocusState != FocusState.Unfocused) return;
            if (e.Key == Windows.System.VirtualKey.Left) { e.Handled = true; Move(-1); }
            if (e.Key == Windows.System.VirtualKey.Right) { e.Handled = true; Move(1); }
        };
        Render();
        Loaded += async (_, _) => { _title.Focus(FocusState.Programmatic); await LoadAsync(); };
    }

    /// <summary>打开新建弹窗；创建成功后回调新简历 id（空串表示服务端没返回 id）。</summary>
    public static void Show(XamlRoot root, string? initialTemplateId, Action<string> created)
    {
        V3Overlay? overlay = null;
        var sheet = (ResumeCreateSheet?)null;
        overlay = V3Overlay.Show(root, close =>
        {
            sheet = new ResumeCreateSheet(initialTemplateId, id => { close(); created(id); }, close);
            return sheet.Frame();
        }, dismissible: true);
    }

    ResumeTemplate? Selected => _index >= 0 && _index < _templates.Count ? _templates[_index] : null;

    FrameworkElement Frame()
    {
        var height = Math.Min(900, (XamlRootHeight() ?? 948) - 48);
        var dialog = V3Dialog.Make(this, [], _close, 760, closable: true, padded: false);
        dialog.Height = height;
        return dialog;
    }

    static double? XamlRootHeight() => App.MainWindow.Content?.XamlRoot?.Size.Height;

    void PaintTitle() => _title.BorderBrush = Brush(_error is not null ? Red : _title.FocusState != FocusState.Unfocused ? Txt : Cl);

    void Render()
    {
        _host.Children.Clear();
        _host.RowDefinitions.Clear();
        _host.RowDefinitions.Add(new RowDefinition { Height = Auto });
        _host.RowDefinitions.Add(new RowDefinition { Height = Star() });
        _host.RowDefinitions.Add(new RowDefinition { Height = Auto });
        _host.RowDefinitions.Add(new RowDefinition { Height = Auto });

        var chips = HStack(6);
        if (Selected is { } selected)
        {
            chips.Children.Add(Sans(selected.Name, 13, Txt, Medium).Also(t => t.MaxWidth = 360).Pad(0, 0, 4, 0));
            foreach (var tag in selected.StyleCategories.Concat(selected.UseCases).Take(3)) chips.Children.Add(V3Chip.Make(tag));
        }
        else chips.Children.Add(Sans("选一套模板，再起个名字，创建后直接进入编辑器。", 14, Sub));
        var head = VStack(0,
            Label("新建简历", 20, Txt, Semibold).Frame(height: 29).Pad(0, 0, 40, 0),
            chips.Frame(height: 20).Top(7));
        head.Padding = new Thickness(32, 28, 32, 0);
        _host.Children.Add(head);

        var stage = Stage();
        stage.Margin = new Thickness(31, 20, 31, 0);
        Grid.SetRow(stage, 1);
        _host.Children.Add(stage);

        var name = VStack(10,
            Spread(Sans("简历名称", 13, Txt, Medium), Sans("只给自己看，方便在列表里区分", 11.5, Fnt)).Frame(height: 20),
            _title);
        _title.IsEnabled = !_busy;
        PaintTitle();
        if (_error is { } error) name.Children.Add(Sans(error, 12.5, Red).Wrap());
        name.Padding = new Thickness(32, 20, 32, 24);
        Grid.SetRow(name, 2);
        _host.Children.Add(name);

        // 页脚（Swift `left:` / `foot:`）：V3Dialog 的页脚放在内容之外，这里自己排，保持 88 高、顶线分隔
        var left = HStack(20);
        if (_templates.Count > 0) left.Children.Add(Sans($"第 {_index + 1} / {_templates.Count} 套", 11.5, Sub, Medium).Tip("当前模板位置"));
        left.Children.Add(Sans("模板之后可以在编辑器里随时切换", 11.5, Fnt));
        var foot = HStack(10,
            new V3Button("取消", _close, height: 36, width: 80) { Enabled = !_busy },
            new V3Button(_busy ? "正在创建…" : "创建并进入编辑器", Submit, V3Button.Kind.Dark, height: 36, width: 148) { Enabled = !(_busy || _loading || _loadFailed || Selected is null) });
        var footer = Spread(left, foot, 10);
        footer.Padding = new Thickness(32, 0, 32, 0);
        footer.MinHeight = 88;
        var footBorder = new Border { Child = footer, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        Grid.SetRow(footBorder, 3);
        _host.Children.Add(footBorder);
    }

    FrameworkElement Stage()
    {
        UIElement content;
        if (_loading) content = Sans("正在加载简历模板…", 12.5, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        else if (_loadFailed)
            content = VStack(12, Sans("模板暂时无法加载，请检查网络后重试。", 12.5, Sub),
                new V3Button("重新加载", () => _ = LoadAsync(), icon: "arrow.clockwise").Align(HorizontalAlignment.Center))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        else if (_templates.Count == 0) content = Sans("当前没有可用模板，暂时无法新建简历。", 12.5, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        else
        {
            var selected = Selected!;
            var paper = new Border { CornerRadius = new CornerRadius(4), Child = TemplateThumbnail.Make(selected, false) }.Elevate(12);
            var viewbox = new Viewbox { Stretch = Stretch.Uniform, Child = new Border { Width = 210, Height = 297, Child = paper }, Margin = new Thickness(76, 24, 76, 24) };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(viewbox, $"{selected.Name}，已选择");
            var nav = Spread(NavButton("chevron.left", "上一个模板", () => Move(-1)), NavButton("chevron.right", "下一个模板", () => Move(1)));
            nav.Margin = new Thickness(20, 0, 20, 0);
            content = Layer(viewbox, nav);
        }
        return new V3DotStage(content, null);
    }

    FrameworkElement NavButton(string symbol, string label, Action action)
    {
        var disabled = _busy || _templates.Count < 2;
        return new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon(symbol, 12, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = disabled ? 0.4 : 1,
        }.Elevate(3).OnTap(action, label, () => !disabled);
    }

    void Move(int direction)
    {
        if (_templates.Count <= 1) return;
        _index = (_index + direction + _templates.Count) % _templates.Count;
        _error = null;
        Render();
    }

    async Task LoadAsync()
    {
        _loading = true; _loadFailed = false; Render();
        try
        {
            _templates = (await App.Session.Api.ListResumeTemplatesAsync()).Where(t => !ResumeRequest.RetiredTemplateKeys.Contains(t.Key)).ToList();
            _index = Math.Max(0, _initialTemplateId is { } id ? _templates.FindIndex(t => t.Id == id) : 0);
        }
        catch (Exception) { _loadFailed = true; }
        finally { _loading = false; Render(); }
    }

    async void Submit()
    {
        if (_busy) return;
        var name = _title.Text.Trim();
        if (name.Length == 0) { _error = "请输入简历名称。"; Render(); _title.Focus(FocusState.Programmatic); return; }
        if (Selected is not { } selected) { _error = "请先选择一套简历模板。"; Render(); return; }
        _busy = true; _error = null; Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/resumes", "POST", body: new JsonObject { ["title"] = name, ["template_id"] = selected.Id, ["guide"] = true });
            _busy = false;
            _created((result["resume"] ?? result).Display("id"));
            return;
        }
        catch (Exception error)
        {
            if (SheetErrors.Unauthorized(error)) { _busy = false; Render(); return; }
            _error = SheetErrors.Server(error, out _, out var code)
                ? code switch
                {
                    "INVALID_RESUME_TITLE" => "请输入 1–255 个字符的简历名称。",
                    "RESUME_TITLE_CONFLICT" => "该名称已经存在，请换一个名称。",
                    "TEMPLATE_INACTIVE" => "所选模板已不可用，请重新选择。",
                    "RESUME_LIMIT_REACHED" => $"已达到 {ResumeRequest.MaximumPerUser} 份上限。删除不用的简历后，才能新建或复制。",
                    _ => "创建简历失败，请稍后重试。",
                }
                : "网络中断，无法确认是否已创建。请先查看简历列表，避免重复创建。";
        }
        _busy = false;
        Render();
        _title.Focus(FocusState.Programmatic);
    }
}

/// <summary>
/// 导入简历（Web `ResumeImportDialog`，02.1b），对应 Mac `ResumeImportSheet`：拖入或选择 Markdown/DOCX/PDF（最大 10 MB），可移除文件、修改名称（默认取文件名），
/// 导入默认版式取管理端排序的第一套模板，上传完成后后端开始解析。560 宽；未选文件时是 184 高的点阵拖放区，选中后是 116 高插图与 64 高文件行；
/// 页脚左侧提示、积分说明、取消 80 与「导入并开始解析」132。
/// </summary>
public sealed class ResumeImportSheet : UserControl
{
    readonly Action _close;
    readonly Action<string> _accepted;
    readonly StackPanel _body = new();
    readonly V3TextInput _title;
    readonly Border _frame;
    string? _file;
    bool _busy, _targeted;
    TextBlock? _left;
    V3Button? _cancel, _submit;

    ResumeImportSheet(Action close, Action<string> accepted)
    {
        _close = close;
        _accepted = accepted;
        _title = new V3TextInput("简历名称", "例如：张三｜产品经理", submit: Submit);
        _title.Box.TextChanged += (_, _) => _title.Error = null;
        _cancel = new V3Button("取消", close, height: 36, width: 80);
        _submit = new V3Button("导入并开始解析", Submit, V3Button.Kind.Dark, height: 36, width: 132);
        _left = Sans("未选择文件", 11.5, Fnt);
        _frame = V3Dialog.Make(_body, [FeatureCostLabel.Make("resume_import"), _cancel, _submit], close, 560, left: [_left]);
        Content = _frame;
        Render();
    }

    public static void Show(XamlRoot root, Action<string> accepted, string? initialFile = null) =>
        V3Overlay.Show(root, close =>
        {
            var sheet = new ResumeImportSheet(close, title => { close(); accepted(title); });
            if (initialFile is not null) sheet.Choose(initialFile);
            return sheet;
        });

    void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(V3DialogHead.Make("导入简历", "AI 会把文件拆成可编辑的模块，之后可以随时修改。"));
        if (_file is { } file)
        {
            _body.Children.Add(new V3DotStage(ImportArt.Make(ImportArt.TagOf(System.IO.Path.GetFileName(file))), 116).Top(16));
            _body.Children.Add(FileRow(file).Top(20));
        }
        else _body.Children.Add(DropZone().Top(16));
        _title.Margin = new Thickness(0, 24, 0, 0);
        _title.Box.IsEnabled = !_busy;
        _body.Children.Add(_title);
        _left!.Text = _file is null ? "未选择文件" : "默认使用文件名（不含扩展名），可修改";
        _cancel!.Enabled = !_busy;
        _submit!.Title = _busy ? "正在导入…" : "导入并开始解析";
        _submit.Enabled = !_busy && _file is not null;
    }

    FrameworkElement DropZone()
    {
        var art = ImportArt.Make(null).Frame(height: 104).Align(v: VerticalAlignment.Top);
        var title = Sans("拖入简历文件，或点击选择", 13, Txt, Medium).Frame(height: 16).Align(HorizontalAlignment.Center, VerticalAlignment.Top).Top(120);
        var hint = Sans("支持 Markdown、DOCX、PDF，最大 10 MB", 11, Fnt).Frame(height: 13).Align(HorizontalAlignment.Center, VerticalAlignment.Top).Top(144);
        var stage = new V3DotStage(null, null) { Opacity = _targeted ? 0.85 : 1 };
        var dash = new Rectangle
        {
            RadiusX = 11, RadiusY = 11, Stroke = Brush(_targeted ? 0xDCDCD8u : 0xE9E9E5u), StrokeThickness = 1, StrokeDashArray = [4, 3],
        };
        var zone = new Grid { Height = 182, AllowDrop = true, Background = Brush(Clear), Children = { stage, dash, art, title, hint } };
        zone.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            if (!_targeted) { _targeted = true; Render(); }
        };
        zone.DragLeave += (_, _) => { _targeted = false; Render(); };
        zone.Drop += async (_, e) =>
        {
            _targeted = false;
            var items = await e.DataView.GetStorageItemsAsync();
            if (items.FirstOrDefault() is { } first) Choose(first.Path);
            else Render();
        };
        return zone.OnTap(() => _ = PickAsync(), "选择 Markdown、DOCX 或 PDF 文件", () => !_busy);
    }

    /// <summary>`.hv3-file`：圆角 12 的白卡，64 高一行（格式色块 36、名称 13/500、大小 11、「移除文件」链接），导入中下方加进度条。</summary>
    FrameworkElement FileRow(string file)
    {
        var name = System.IO.Path.GetFileName(file);
        var tag = ImportArt.TagOf(name);
        long size = 0;
        try { size = new FileInfo(file).Length; } catch (Exception) { }
        var badge = new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(8), Background = Brush(tag.Soft),
            Child = Number(tag.Label, 9.5, tag.Color, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        var remove = Sans("移除文件", 14, Sub, Medium).OnTap(() => { _file = null; _title.Text = ""; Render(); }, "移除文件", () => !_busy);
        var row = Columns(12,
            (Auto, badge),
            (Star(), VStack(5, Sans(name, 13, Txt, Medium).Frame(height: 16), Number(ByteCount(size), 11, Fnt, Medium).Frame(height: 13)).Align(v: VerticalAlignment.Center)),
            (Auto, remove.Align(v: VerticalAlignment.Center)));
        row.Height = 64;
        row.Padding = new Thickness(14, 0, 18, 0);
        var stack = VStack(0, row);
        if (_busy)
        {
            var progress = VStack(10,
                Sans("正在导入… 上传完成后自动开始解析", 11.5, Sub).Frame(height: 14),
                new ProgressBar { IsIndeterminate = true, Height = 4, Foreground = Brush(Txt) }.Tip($"{name} 正在导入"));
            stack.Children.Add(new Border
            {
                Child = progress, Padding = new Thickness(0, 11, 0, 15), Margin = new Thickness(18, 0, 18, 0),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0),
            });
        }
        return Card(stack, 12);
    }

    /// <summary>`ByteCountFormatter(countStyle: .file)`：十进制单位（1 KB = 1000 字节）。</summary>
    static string ByteCount(long bytes)
    {
        if (bytes < 1000) return bytes == 1 ? "1 byte" : $"{bytes} bytes";
        string[] units = ["KB", "MB", "GB"];
        double value = bytes;
        var unit = -1;
        do { value /= 1000; unit++; } while (value >= 1000 && unit < units.Length - 1);
        return unit == 0 ? $"{Math.Round(value):0} {units[unit]}" : $"{value:0.#} {units[unit]}";
    }

    async Task PickAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var ext in new[] { ".pdf", ".md", ".docx" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        if (await picker.PickSingleFileAsync() is { } file) Choose(file.Path);
    }

    void Choose(string path)
    {
        var ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!ResumeImportUpload.Types.ContainsKey(ext)) { _title.Error = "选择 Markdown、DOCX 或 PDF 文件"; Render(); return; }
        _file = path;
        _title.Text = System.IO.Path.GetFileNameWithoutExtension(path);
        _title.Error = null;
        Render();
    }

    async void Submit()
    {
        if (_busy) return;
        if (_file is not { } file) { _title.Error = "请先选择需要导入的文件。"; return; }
        if (ResumeImportUpload.TitleError(_title.Text) is { } message) { _title.Error = message; return; }
        _busy = true; _title.Error = null; Render();
        try
        {
            var templates = await App.Session.Api.ListResumeTemplatesAsync();
            if (templates.FirstOrDefault() is not { } template) { _title.Error = "导入所需的默认版式暂时不可用，请稍后重试。"; return; }
            var upload = new ResumeImportUpload(file, template.Id, _title.Text);
            if (App.Session.Api is not HttpApiClient client) throw new InvalidOperationException();
            await client.Coordinator.ImportResumeAsync(upload.FileName, upload.ContentType, upload.Content, upload.TemplateID, upload.IdempotencyKey);
            _busy = false;
            _accepted(_title.Text.Trim());
            return;
        }
        catch (Exception error)
        {
            if (SheetErrors.Unauthorized(error)) return;
            _title.Error = ResumeImportUpload.ErrorMessage(error);
        }
        finally { _busy = false; Render(); }
    }
}

/// <summary>Web `ImportArt`，对应 Mac `ImportArt`：多份文件纸（MD / DOCX / PDF）或单份带格式的纸，经虚线箭头变成分好模块的简历纸，右上一个 spark 角标。</summary>
public static class ImportArt
{
    public sealed record Tag(string Label, Color Color, Color Soft);

    public static Tag TagOf(string name) => System.IO.Path.GetExtension(name).TrimStart('.').ToLowerInvariant() switch
    {
        "pdf" => new Tag("PDF", Hex(0xD9822B), Hex(0xFBEFE3)),
        "docx" or "doc" => new Tag("DOCX", Blue, BlueSoft),
        _ => new Tag("MD", Sub, Field),
    };

    public static FrameworkElement Make(Tag? single)
    {
        var canvas = new Canvas { Width = 496, Height = single is null ? 104 : 116, IsHitTestVisible = false };
        if (single is not null) Put(canvas, Paper(48, 62, single.Label, single.Color, 6), 168, 22);
        else
        {
            Put(canvas, Paper(46, 60, "MD", Sub, 10), 128, 22);
            Put(canvas, Paper(46, 60, "DOCX", Blue, 2), 150, 18);
            Put(canvas, Paper(46, 60, "PDF", Hex(0xD9822B), -6), 172, 22);
        }
        Put(canvas, Arrow(), 232, 46);
        Put(canvas, Modules(single is null ? 3 : 2), 284, 14);
        var spark = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Brush(Txt),
            Child = Icon("sparkle", 11, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.Elevate(3);
        Put(canvas, spark, 346, 6);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return canvas.Align(HorizontalAlignment.Center, VerticalAlignment.Top);
    }

    static void Put(Canvas canvas, FrameworkElement element, double x, double y)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        canvas.Children.Add(element);
    }

    static FrameworkElement Bar(double x, double y, double w, double h, Color? color = null, double r = 1) => new Border
    {
        Width = w, Height = h, CornerRadius = new CornerRadius(r), Background = Brush(color ?? Hex(0xECECEA)),
        HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(x, y, 0, 0),
    };

    static Border Sheet(double w, double h, params UIElement[] content)
    {
        var grid = new Grid();
        foreach (var child in content) grid.Children.Add(child);
        return new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(5), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Child = grid,
        }.Elevate(6);
    }

    static FrameworkElement Paper(double w, double h, string tag, Color color, double rotate)
    {
        var label = new Border
        {
            Width = tag.Length > 2 ? 30 : 24, Height = 13, CornerRadius = new CornerRadius(3), Background = Brush(color),
            Child = Label(tag, 7.5, V3.White, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(7, h - 20, 0, 0),
        };
        var sheet = Sheet(w, h, Bar(7, 9, w * 0.55, 4, Hex(0xDCDCD8), 2), Bar(7, 18, w * 0.7, 3, null, 2), Bar(7, 25, w * 0.5, 3, null, 2), label);
        sheet.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
        sheet.RenderTransform = new RotateTransform { Angle = rotate };
        return sheet;
    }

    static FrameworkElement Modules(int filled)
    {
        var parts = new List<UIElement> { Bar(9, 9, 30, 5, Txt), Bar(9, 18, 46, 3, Hex(0xDCDCD8)) };
        double[] tops = [28, 48, 67];
        for (var index = 0; index < tops.Length; index++)
        {
            if (index < filled)
                parts.Add(new Border
                {
                    Width = 58, Height = 15, CornerRadius = new CornerRadius(3), Background = Brush(Field),
                    HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(9, tops[index], 0, 0),
                    Child = new Grid { Children = { Bar(5, 3.5, 24, 3, Hex(0xDCDCD8)), Bar(5, 9, 38, 2.5) } },
                });
            else
                parts.Add(new Rectangle
                {
                    Width = 58, Height = 15, RadiusX = 3, RadiusY = 3, Stroke = Brush(0xE9E9E5), StrokeThickness = 1, StrokeDashArray = [3, 2],
                    HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(9, tops[index], 0, 0),
                });
        }
        return Sheet(76, 88, parts.ToArray());
    }

    static FrameworkElement Arrow()
    {
        var stroke = Brush(0xB9B9B3);
        var line = new Microsoft.UI.Xaml.Shapes.Line { X1 = 2, Y1 = 7, X2 = 34, Y2 = 7, Stroke = stroke, StrokeThickness = 1.4, StrokeDashArray = [3 / 1.4, 3 / 1.4] };
        var head = new Polyline
        {
            Points = { new Windows.Foundation.Point(34, 3), new Windows.Foundation.Point(39, 7), new Windows.Foundation.Point(34, 11) },
            Stroke = stroke, StrokeThickness = 1.4, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        };
        return new Canvas { Width = 44, Height = 14, Children = { line, head } };
    }
}

/// <summary>
/// Web `FeatureCost`，对应 Mac `FeatureCostLabel`：后台配置的功能价格（`GET /api/billing/feature-prices`，每次启动读一次），读不到时按用量计。
/// </summary>
public static class FeatureCostLabel
{
    static List<JsonNode>? _cache;

    public static TextBlock Make(string code)
    {
        var label = Sans("按实际用量消耗积分", 12, Sub).Frame(height: 18);
        label.Loaded += async (_, _) =>
        {
            if (_cache is null)
                try { _cache = (await App.Session.Api.CareerRequestAsync("/api/billing/feature-prices")).Items("items"); }
                catch (Exception) { }
            label.Text = Text(_cache?.FirstOrDefault(x => x.Text("featureCode") == code));
        };
        return label;
    }

    public static string Text(JsonNode? price)
    {
        var raw = price.Get("unitPoints");
        var points = raw.String() is { } text && double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? parsed : raw.Number();
        // NumberFormatter(.decimal, 最多 2 位小数, en_US)：千分位逗号
        var value = points?.ToString("#,##0.##", System.Globalization.CultureInfo.InvariantCulture);
        return price.Text("priceMode") switch
        {
            "fixed" when value is not null => $"消耗 {value} 积分",
            "per_minute" when value is not null => $"每分钟 {value} 积分",
            "free" => "本次免费",
            _ => "按实际用量消耗积分",
        };
    }
}
