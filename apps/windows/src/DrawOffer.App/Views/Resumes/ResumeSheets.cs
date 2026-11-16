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

/// <summary>03 页弹窗（02.1a–02.1f）公共件：浅灰提示字、插图里的小简历纸、虚线箭头、白底设置块。</summary>
static class SheetKit
{
    /// <summary>稿中标签、提示与计数的浅灰字 #96968F。</summary>
    public static readonly Color Hint = Hex(0x96968F);

    /// <summary>一张小简历纸（标题条 + 几道灰线），弹窗插图用。</summary>
    public static Border Paper(double width = 50, double height = 68)
    {
        var lines = VStack(height * 0.05,
            Fill(Txt, 1, width * 0.42, Math.Max(3, height * 0.06)).Align(HorizontalAlignment.Left),
            Fill(Hex(0xDCDCD8), 1, width * 0.6, 2).Align(HorizontalAlignment.Left));
        for (var i = 0; i < 4; i++) lines.Children.Add(Fill(V3.Line, 1, width * (i == 3 ? 0.45 : 0.7), 2).Align(HorizontalAlignment.Left));
        return new Border
        {
            Width = width, Height = height, Padding = new Thickness(width * 0.14), CornerRadius = new CornerRadius(4), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Child = lines,
        };
    }

    /// <summary>灰色虚线箭头（插图里“变成”的意思）。</summary>
    public static Canvas Arrow(double width, double height)
    {
        var stroke = Brush(0xB9B9B3);
        var mid = height / 2;
        var line = new Microsoft.UI.Xaml.Shapes.Line { X1 = 2, Y1 = mid, X2 = width - 6, Y2 = mid, Stroke = stroke, StrokeThickness = 1.4, StrokeDashArray = [3 / 1.4, 3 / 1.4] };
        var head = new Polyline
        {
            Points = { new Windows.Foundation.Point(width - 6, mid - 3.5), new Windows.Foundation.Point(width - 2, mid), new Windows.Foundation.Point(width - 6, mid + 3.5) },
            Stroke = stroke, StrokeThickness = 1.4, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        };
        return new Canvas { Width = width, Height = height, Children = { line, head } };
    }

    /// <summary>设置块：白底、#E4E4E0 细边、圆角 12，行之间细线分隔。</summary>
    public static Border Settings(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (var i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(Divider());
            stack.Children.Add(rows[i]);
        }
        return new Border
        {
            Child = stack, Padding = new Thickness(17, 0, 17, 0), CornerRadius = new CornerRadius(11.5), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
    }

    /// <summary>设置行：60 高，左侧 13/500 标题 + 11 号浅灰说明，右侧控件。</summary>
    public static Grid Row(string title, string hint, UIElement control) =>
        Spread(VStack(5, Sans(title, 13, Txt, Medium), Sans(hint, 11, Hint)).Align(v: VerticalAlignment.Center), control, 12).Frame(height: 60);

    /// <summary>纯文字链（弹窗左下）：12/500，可带前置图标。</summary>
    public static FrameworkElement TextLink(string title, Action action, Color color, string? icon = null, Func<bool>? enabled = null)
    {
        var row = HStack(6);
        if (icon is not null) row.Children.Add(Icon(icon, 10, color).Align(v: VerticalAlignment.Center));
        row.Children.Add(Sans(title, 12, color, Medium));
        row.Background = Brush(Clear);
        return row.OnTap(action, title, enabled);
    }
}

/// <summary>
/// 重命名（Windows 稿 02.1e，Web `RenameResumeDialog`）与复制为新简历。重命名只改列表标题，不写入正文；
/// 复制携带固定的 `client_request_id`，结果不确定时重试不会多复制一份。
/// 480 宽：标题 + 一句说明，96 高点阵舞台（小纸 + 正在改的名称签），「简历名称」输入框；
/// 重命名时下面一块「想按另一个岗位改？」带「复制为新简历 →」；底栏取消 + 墨黑保存。
/// </summary>
public static class ResumeTitleSheet
{
    public enum Mode { Rename, Copy }

    public static void Show(XamlRoot root, Mode mode, ResumeSummary resume, Action<string> done, Action? copy = null)
    {
        var busy = false;
        var requestId = Guid.NewGuid().ToString("D").ToLowerInvariant();
        var input = new V3TextInput("简历名称", "例如：后端工程师 · 字节跳动", mode == Mode.Rename ? resume.Title : $"{resume.Title} 副本");
        var nameTag = Sans("", 11.5, Txt, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        V3Button cancel = null!, submit = null!;
        Action closeSheet = () => { };
        string Normalized() => input.Text.Trim();
        void Paint()
        {
            var name = Normalized();
            nameTag.Text = name.Length == 0 ? resume.Title : name;
            submit.Title = busy ? "正在保存…" : mode == Mode.Rename ? "保存名称" : "确认复制";
            submit.Enabled = !busy && name.Length > 0 && !(mode == Mode.Rename && name == resume.Title);
            cancel.Enabled = !busy;
            input.Box.IsEnabled = !busy;
        }
        async void Submit()
        {
            var name = Normalized();
            if (busy || name.Length == 0) return;
            if (name.Length > 255 || name.Any(c => c is '\n' or '\r')) { input.Error = "名称无效，请输入 1–255 个字符且不含换行。"; return; }
            if (mode == Mode.Rename && name == resume.Title) { closeSheet(); return; }
            busy = true; input.Error = null; Paint();
            try
            {
                if (mode == Mode.Rename)
                    await App.Session.Api.CareerRequestAsync($"/api/resumes/{resume.Id}", "PUT", body: new JsonObject { ["title"] = name, ["base_lock_version"] = resume.LockVersion });
                else
                    await App.Session.Api.CareerRequestAsync($"/api/resumes/{resume.Id}/copy", "POST",
                        body: new JsonObject { ["title"] = name, ["base_lock_version"] = resume.LockVersion, ["client_request_id"] = requestId });
                busy = false;
                closeSheet();
                done(name);
                return;
            }
            catch (Exception failure)
            {
                SheetErrors.Unauthorized(failure);
                var fallback = mode == Mode.Rename ? "保存名称失败，请刷新列表后重试。" : "复制失败，请检查名称、简历数量或刷新后重试。";
                input.Error = failure is ApiException ? ResumeRequest.ErrorMessage(failure, fallback)
                    : mode == Mode.Copy ? "网络中断，结果尚未确认。可以直接重试，不会重复复制。" : "网络中断，结果尚未确认，请重试。";
            }
            busy = false; Paint();
        }
        input.Box.TextChanged += (_, _) => { input.Error = null; if (mode == Mode.Copy) requestId = Guid.NewGuid().ToString("D").ToLowerInvariant(); Paint(); };
        input.Box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Submit(); } };
        input.Box.Loaded += (_, _) => input.Box.SelectAll();
        V3Overlay.Show(root, close =>
        {
            closeSheet = close;
            cancel = new V3Button("取消", () => { if (!busy) close(); }, height: 36);
            submit = new V3Button("", Submit, V3Button.Kind.Dark, height: 36);
            // 插图：小纸 + 正在改的名称签（墨黑细边）+ 右上一个笔形角标
            var tag = new Border
            {
                Width = 160, Height = 34, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
                BorderBrush = Brush(Txt), BorderThickness = new Thickness(1), Child = nameTag.Align(v: VerticalAlignment.Center),
            };
            var badge = new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Brush(Txt), Margin = new Thickness(0, -12, -10, 0),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                Child = Icon(mode == Mode.Copy ? "doc.on.doc" : "pencil", 9, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            };
            var art = HStack(16, SheetKit.Paper(), Layer(tag, badge).Align(v: VerticalAlignment.Center)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            var body = VStack(0,
                V3DialogHead.Make(mode == Mode.Rename ? "重命名简历" : "复制为新简历",
                    mode == Mode.Rename ? "名称只给自己看，方便在列表里区分。" : $"基于「{resume.Title}」的当前版本复制一份，原简历不受影响。", subTop: 2, subLine: 20),
                new V3DotStage(art, 96).Top(23),
                input.Top(20));
            if (mode == Mode.Rename && copy is not null)
            {
                var link = HStack(5, Sans("复制为新简历", 12, Txt, Medium), Icon("arrow.right", 9, Txt).Align(v: VerticalAlignment.Center));
                link.Background = Brush(Clear);
                body.Children.Add(new Border
                {
                    Height = 59, Padding = new Thickness(17, 0, 17, 0), CornerRadius = new CornerRadius(11.5), Background = Brush(V3.White),
                    BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
                    Child = Spread(VStack(5, Sans("想按另一个岗位改？", 13, Txt, Medium), Sans("复制后得到独立简历，两份内容互不影响。", 11, SheetKit.Hint)).Align(v: VerticalAlignment.Center),
                        link.OnTap(() => { close(); copy(); }, "复制为新简历", () => !busy).Align(v: VerticalAlignment.Center)),
                }.Top(24));
            }
            Paint();
            return V3Dialog.Make(body, [cancel, submit], close, 480);
        }, dismissible: true);
    }
}

/// <summary>
/// 分享简历（Windows 稿 02.1d，Web `features/home/SharePanel.tsx`）：生成只读链接，设置谁可以查看、有效期与是否允许下载 PDF，
/// 支持复制、重新生成和删除链接。链接为 `{站点 origin}/share/{token}`。
/// 520 宽：标题 + 说明，116 高点阵舞台（简历 → 公开页），44 高灰底链接行（链接图标 + 地址 + 墨黑「复制链接」），
/// 一行状态（绿点「链接可用 · 有效至…」），圆角 12 的设置块；底栏左侧「重新生成链接」「删除链接」，右侧「完成」。
/// 还没有链接时设置块在前，底栏「取消」+「创建分享链接」。
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
    readonly StackPanel _body = new();
    readonly StackPanel _left = HStack(20);
    readonly StackPanel _foot = HStack(8);
    ResumeShare? _share;
    bool _loaded, _loadFailed, _busy, _copied;
    string? _error;
    bool _createPublic = true, _createAllowDownload = true;
    Expiry _createExpiry = Expiry.Week;

    ResumeShareSheet(ResumeSummary resume, Action close)
    {
        _resume = resume;
        _close = close;
        Content = V3Dialog.Make(_body, [_foot], () => { if (!_busy) close(); }, 520, left: [_left]);
        Render();
        Loaded += async (_, _) => await LoadAsync();
    }

    public static void Show(XamlRoot root, ResumeSummary resume) => V3Overlay.Show(root, close => new ResumeShareSheet(resume, close));

    Uri? Origin => (App.Session.Api as HttpApiClient)?.Coordinator.Origin;

    void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(V3DialogHead.Make("分享简历", $"为「{_resume.Title}」生成只读链接，对方不用登录就能查看。", subTop: 2, subLine: 20));
        _body.Children.Add(new V3DotStage(Art(_share?.IsPublic ?? _createPublic), 116).Top(23));
        if (!_loaded && !_loadFailed)
            _body.Children.Add(HStack(8, new ProgressRing { Width = 16, Height = 16, IsActive = true }, Sans("正在读取分享状态…", 13, Sub))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center).Frame(height: 120));
        else if (_loadFailed)
            _body.Children.Add(Spread(Sans("分享状态读取失败，请稍后重试。", 13, Red), new V3Button("重试", () => _ = LoadAsync())).Frame(height: 80));
        else if (_share is { } share) _body.Children.Add(Existing(share).Top(20));
        else _body.Children.Add(Creation().Top(20));
        if (_error is { } error) _body.Children.Add(Sans(error, 12.5, Red).Wrap().Top(12));

        _left.Children.Clear();
        _foot.Children.Clear();
        if (_loaded && _share is not null)
        {
            _left.Children.Add(SheetKit.TextLink("重新生成链接", () => _ = ConfirmAsync("重新生成分享链接？",
                $"重新生成后旧链接将立即失效，已转发的旧地址无法再访问。「{_resume.Title}」的可见性与下载权限会保留。", "确认重新生成", false, RegenerateAsync), Sub, "arrow.clockwise", () => !_busy));
            _left.Children.Add(SheetKit.TextLink("删除链接", () => _ = ConfirmAsync("删除分享链接？",
                $"删除后旧地址将显示「分享链接已失效」，之后可重新创建。「{_resume.Title}」本身不受影响。", "确认删除", true, DeleteAsync), Red, enabled: () => !_busy));
        }
        if (_loaded && _share is null)
        {
            _foot.Children.Add(new V3Button("取消", _close, height: 36, width: 79));
            _foot.Children.Add(new V3Button(_busy ? "正在创建…" : "创建分享链接", () => _ = CreateAsync(), V3Button.Kind.Dark, height: 36) { Enabled = !_busy });
        }
        else _foot.Children.Add(new V3Button("完成", _close, height: 36, width: 108));
    }

    /// <summary>02.1d 插图：简历纸 → 虚线箭头 → 公开页（顶部地址栏），右上「公开 / 仅自己」小签。</summary>
    static FrameworkElement Art(bool isPublic)
    {
        var lines = VStack(5, Fill(Txt, 1, 40, 4).Align(HorizontalAlignment.Left));
        for (var i = 0; i < 4; i++) lines.Children.Add(Fill(V3.Line, 1, i == 3 ? 60 : 110, 2).Align(HorizontalAlignment.Left));
        var address = new Border
        {
            Height = 18, Background = Brush(Field),
            Child = new Border
            {
                Width = 108, Height = 10, CornerRadius = new CornerRadius(5), Background = Brush(V3.White), Padding = new Thickness(6, 0, 6, 0),
                Child = Sans("drawoffer.cn/s/…", 7, SheetKit.Hint).Align(v: VerticalAlignment.Center),
            }.Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        var page = new Border
        {
            Width = 156, Height = 80, CornerRadius = new CornerRadius(5), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = VStack(0, address, lines.Pad(10, 10, 10, 0)),
        };
        var chip = new Border
        {
            Height = 20, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(10), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Sans(isPublic ? "公开" : "仅自己", 10, Sub, Medium).Align(v: VerticalAlignment.Center),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -10, -26, 0),
        };
        return HStack(14, SheetKit.Paper(62, 84), SheetKit.Arrow(37, 8).Align(v: VerticalAlignment.Center), Layer(page, chip).Align(v: VerticalAlignment.Center))
            .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
    }

    static V3Segmented<T> Segment<T>(IEnumerable<(T, string)> options, T selection, string label) where T : notnull
    {
        var segment = new V3Segmented<T>(options, selection, height: 30, fontSize: 12);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(segment, label);
        return segment;
    }

    UIElement Creation()
    {
        var access = Segment([(true, "公开"), (false, "仅自己")], _createPublic, "谁可以查看");
        access.Changed += value => { _createPublic = value; Render(); };
        var expiry = Segment(Enum.GetValues<Expiry>().Select(x => (x, Title(x))), _createExpiry, "链接有效期");
        expiry.Changed += value => _createExpiry = value;
        var download = new V3Switch(_createAllowDownload, "允许下载 PDF") { Enabled = !_busy };
        download.Toggled += on => { _createAllowDownload = on; Render(); };
        var panel = SheetKit.Settings(
            SheetKit.Row("谁可以查看", _createPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开", access),
            SheetKit.Row("链接有效期", "到期后链接自动失效，可以重新生成", expiry),
            SheetKit.Row("允许下载 PDF", _createAllowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载", download));
        panel.IsHitTestVisible = !_busy;
        return panel;
    }

    UIElement Existing(ResumeShare share)
    {
        var expired = share.IsExpired();
        var link = Origin is { } origin ? share.Url(origin).AbsoluteUri : "";
        var linkText = Sans(expired ? "该分享链接已失效，访客将无法继续访问简历" : link.Replace("https://", ""), 13, expired ? Fnt : Txt);
        linkText.TextTrimming = TextTrimming.CharacterEllipsis;
        linkText.IsTextSelectionEnabled = true;
        var copy = new V3Button(expired ? "不可复制" : _copied ? "已复制" : "复制链接", () => Copy(link), V3Button.Kind.Dark, height: 36, width: 100) { Enabled = !expired && link.Length > 0 };
        var linkRow = new Border
        {
            Height = 44, Padding = new Thickness(16, 0, 4, 0), CornerRadius = new CornerRadius(10), Background = Brush(Field),
            Child = Columns(12, (Auto, Icon("link", 11, Sub).Align(v: VerticalAlignment.Center)), (Star(), linkText.Align(v: VerticalAlignment.Center)), (Auto, copy.Align(v: VerticalAlignment.Center))),
        };
        var status = HStack(6,
            new Ellipse { Width = 6, Height = 6, Fill = Brush(expired ? Red : Green), VerticalAlignment = VerticalAlignment.Center },
            Sans(expired ? "链接已过期" : "链接可用", 11.5, Sub, Medium),
            Sans(ExpiryLabel(share), 11.5, SheetKit.Hint)).Pad(14, 12, 0, 0);
        var access = Segment([(true, "公开"), (false, "仅自己")], share.IsPublic, "谁可以查看");
        access.Changed += value => _ = UpdateAsync(new JsonObject { ["visibility"] = value ? "public" : "private" });
        // 已有链接按剩余时长对应到最接近的一档；点哪档就从现在起重新算
        var expiry = Segment(Enum.GetValues<Expiry>().Select(x => (x, Title(x))), Closest(share), "链接有效期");
        expiry.Changed += option => _ = UpdateAsync(new JsonObject { ["expires_at"] = ResumeShare.Encode(Date(option)) });
        var download = new V3Switch(share.AllowDownload, "允许下载 PDF") { Enabled = !_busy };
        download.Toggled += on => _ = UpdateAsync(new JsonObject { ["allow_download"] = on });
        var settings = SheetKit.Settings(
            SheetKit.Row("谁可以查看", share.IsPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开", access),
            SheetKit.Row("链接有效期", "到期后链接自动失效，可以重新生成", expiry),
            SheetKit.Row("允许下载 PDF", share.AllowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载", download));
        var panel = VStack(0, linkRow, status, settings.Top(21));
        panel.IsHitTestVisible = !_busy;
        return panel;
    }

    static Expiry Closest(ResumeShare share)
    {
        if (share.ExpiresAt is not { } expires) return Expiry.Forever;
        return expires - DateTimeOffset.UtcNow > TimeSpan.FromDays(8) ? Expiry.Month : Expiry.Week;
    }

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

    async Task ConfirmAsync(string title, string message, string action, bool danger, Func<Task> run)
    {
        if (await V3Dialog.ConfirmAsync(XamlRoot, title, message, action, danger)) await run();
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
/// 新建简历（Windows 稿 02.1a，Web `ResumeCreateDialog`）：760×660。标题 + 一句说明；①「选择模板」右侧「1 / 8」，276 高点阵舞台里
/// 168×222 的白卡放模板缩略图、下方模板名，左右 36 圆形翻页钮（← → 键）；②「简历名称」右侧一句说明，43 高输入框（聚焦墨黑边），
/// 下方常用写法；底栏左侧提示，右侧取消与墨黑「创建并进入编辑器」148。
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
        PlaceholderText = "例如：后端工程师 · 字节跳动", FontSize = 13.5, FontFamily = SansFamily, Height = 43, MinHeight = 0, MaxLength = 255,
        Padding = new Thickness(13, 11, 13, 0), CornerRadius = new CornerRadius(9.25), BorderThickness = new Thickness(1),
        Background = Brush(V3.White), Foreground = Brush(Txt), PlaceholderForeground = Brush(Fnt2),
    };
    readonly StackPanel _body = new() { Padding = new Thickness(32, 31, 32, 16) };
    readonly V3Button _cancel, _submit;

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
        _cancel = new V3Button("取消", () => { if (!_busy) close(); }, height: 36, width: 79);
        _submit = new V3Button("创建并进入编辑器", Submit, V3Button.Kind.Dark, height: 36, width: 148);
        var dialog = V3Dialog.Make(_body, [_cancel, _submit], close, 760, padded: false,
            left: [Sans("模板之后可以在编辑器里随时切换", 11.5, SheetKit.Hint)]);
        dialog.Height = 660;
        Content = dialog;
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
    public static void Show(XamlRoot root, string? initialTemplateId, Action<string> created) =>
        V3Overlay.Show(root, close => new ResumeCreateSheet(initialTemplateId, id => { close(); created(id); }, close), dismissible: true);

    ResumeTemplate? Selected => _index >= 0 && _index < _templates.Count ? _templates[_index] : null;

    void PaintTitle() => _title.BorderBrush = Brush(_error is not null ? Red : _title.FocusState != FocusState.Unfocused ? Txt : Cl);

    /// <summary>步骤标题：20 圆形序号（当前一步墨黑底白字，其余灰底），13/500 标题，右侧补充。</summary>
    static Grid Step(int number, string title, bool active, UIElement? trailing)
    {
        var dot = new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Brush(active ? Txt : Field),
            Child = Number($"{number}", 10.5, active ? V3.White : Sub, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        return Spread(HStack(8, dot, Sans(title, 13, Txt, Medium).Align(v: VerticalAlignment.Center)), trailing ?? new Grid()).Frame(height: 20);
    }

    void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(V3DialogHead.Make("新建简历", "选一套模板，再起个名字，创建后直接进入编辑器。", subTop: 2, subLine: 20));
        _body.Children.Add(Step(1, "选择模板", true,
            _templates.Count > 0 ? Number($"{_index + 1} / {_templates.Count}", 11.5, SheetKit.Hint, Medium).Tip("当前模板位置") : null).Top(27));
        _body.Children.Add(Stage().Top(12));
        _body.Children.Add(Step(2, "简历名称", false, Sans("只给自己看，方便在列表里区分", 11.5, SheetKit.Hint)).Top(28));
        if (_title.Parent is Panel old) old.Children.Remove(_title);
        _title.IsEnabled = !_busy;
        PaintTitle();
        _body.Children.Add(_title.Top(13));
        _body.Children.Add(Sans(_error ?? "常用写法：岗位 · 公司，例如「产品经理 · 美团」", 11, _error is not null ? Red : SheetKit.Hint).Wrap().Top(8));
        _cancel.Enabled = !_busy;
        _submit.Title = _busy ? "正在创建…" : "创建并进入编辑器";
        _submit.Enabled = !(_busy || _loading || _loadFailed || Selected is null);
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
            var card = new Border
            {
                Width = 168, Padding = new Thickness(14), CornerRadius = new CornerRadius(6), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
                Child = new Border { Width = 139, Height = 139 * 297 / 210.0, Child = TemplateThumbnail.Make(selected, false) },
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"{selected.Name}，已选择");
            var name = Sans(string.Join(" · ", new[] { selected.Name }.Concat(selected.StyleCategories.Take(1))), 12.5, Txt, Medium).Align(HorizontalAlignment.Center);
            var preview = VStack(10, card, name).Align(HorizontalAlignment.Center, VerticalAlignment.Center).Top(2);
            var nav = HStack(216, NavButton("chevron.left", "上一个模板", () => Move(-1)), NavButton("chevron.right", "下一个模板", () => Move(1)))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            nav.Margin = new Thickness(0, 0, 0, 16);
            content = Layer(preview, nav);
        }
        return new V3DotStage(content, 276);
    }

    FrameworkElement NavButton(string symbol, string label, Action action)
    {
        var disabled = _busy || _templates.Count < 2;
        return new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon(symbol, 11, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = disabled ? 0.4 : 1,
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
/// 删除确认（Windows 稿 02.1f）：420 宽；128 高点阵舞台（三张纸、中间一张压垃圾桶角标），居中标题 18/600 与「名称 · 删除后无法恢复」，
/// 灰底影响清单（分享链接失效 / 求职记录解除关联 / 其他简历不受影响），底栏等宽「取消」与红色「删除」。
/// </summary>
public static class ResumeDeleteSheet
{
    public static void Show(XamlRoot root, ResumeSummary resume, Func<ResumeSummary, Task> delete)
    {
        var busy = false;
        V3Overlay.Show(root, close =>
        {
            V3Button cancel = null!, confirm = null!;
            cancel = new V3Button("取消", () => { if (!busy) close(); }, height: 36);
            confirm = new V3Button("删除", async () =>
            {
                if (busy) return;
                busy = true; confirm.Title = "正在删除…"; confirm.Enabled = false; cancel.Enabled = false;
                await delete(resume);
                busy = false;
                close();
            }, V3Button.Kind.Danger, height: 36);
            Border Side() { var paper = SheetKit.Paper(); paper.Opacity = 0.85; return paper; }
            var middle = SheetKit.Paper(58, 80);
            var trash = new Border
            {
                Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Background = Brush(V3.White), BorderBrush = Brush(0xF3D6D6), BorderThickness = new Thickness(1),
                Child = Icon("trash", 10, Red).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, -13, -10),
            };
            var art = HStack(11, Side().Top(8), Layer(middle, trash), Side().Top(8)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            FrameworkElement Impact(string symbol, string text) => HStack(12, Icon(symbol, 10, Sub).Frame(12).Align(v: VerticalAlignment.Center), Sans(text, 12, Sub));
            var impacts = new Border
            {
                Padding = new Thickness(18, 16, 18, 16), CornerRadius = new CornerRadius(10), Background = Brush(Field),
                Child = VStack(12, Impact("link", "公开分享链接会立即失效"), Impact("briefcase", "关联的求职记录会解除关联"), Impact("doc.text", "其他简历不受影响")),
            };
            var body = VStack(0,
                new V3DotStage(art, 128),
                Label("删除这份简历？", 18, Txt, Semibold).Frame(height: 26).Align(HorizontalAlignment.Center).Top(23),
                Sans($"{resume.Title} · 删除后无法恢复", 12.5, Sub).Wrap().Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxLines = 2; }).Align(HorizontalAlignment.Center).Top(3),
                impacts.Top(17));
            return V3Dialog.Make(body, [cancel, confirm], () => { if (!busy) close(); }, 420);
        }, dismissible: true);
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
        _cancel = new V3Button("取消", close, height: 36, width: 79);
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
        _body.Children.Add(V3DialogHead.Make("导入简历", "AI 会把文件拆成可编辑的模块，之后可以随时修改。", subTop: 2, subLine: 20));
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
        var remove = Sans("移除文件", 12, Sub, Medium).OnTap(() => { _file = null; _title.Text = ""; Render(); }, "移除文件", () => !_busy);
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

/// <summary>Web `ImportArt`，对应 Mac `ImportArt`：多份文件纸（MD / DOCX / PDF）或单份带格式的纸，经虚线箭头变成分好模块的简历纸，右上一个对勾角标。</summary>
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
            Child = Icon("checkmark", 11, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
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
