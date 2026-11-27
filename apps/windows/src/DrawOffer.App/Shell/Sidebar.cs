using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>
/// 工作区侧栏（Windows 稿 00 页 Sidebar · NavigationView Pane 6:908）：宽 248、#F1F1EF 底，贴窗口左边到顶。
/// 顶行 48（标题栏拖动区）：左 20 起 logo + 品牌字（Brand / Lockup 142×22，点回首页），右侧通知铃铛；
/// 8 个一级入口（224×36、圆角 4、16 号图标、13px，选中 #E6E6E2 底 + 左侧 3×16 墨黑指示条）；
/// 「最近对话 ⌄」可折叠，右侧「新对话」；对话行纯文字 224×32；底部账户行（头像 24、名字 · 档位、上下箭头），点开个人菜单。
/// </summary>
public sealed class Sidebar : Grid
{
    public const double PaneWidth = 248;

    readonly WorkspaceShell _shell;
    readonly StackPanel _list = new() { Padding = new Thickness(12, 4, 12, 12) };
    readonly Border _user = new();
    readonly HashSet<string> _collapsed = [];
    bool _showAll;
    string? _renaming;
    string? _tier;
    string _tierAccount = "";

    public Sidebar(WorkspaceShell shell)
    {
        _shell = shell;
        Width = PaneWidth;
        Background = Brush(Win);
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(48) });
        RowDefinitions.Add(new RowDefinition { Height = Star() });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var lockup = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/lockup.png")), Width = 142, Height = 22, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left }
            .OnTap(() => _shell.Select(WorkspaceSection.Home), "DrawOffer 首页");
        var header = Spread(lockup, new AnnouncementBell(shell), 8);
        header.Padding = new Thickness(20, 0, 10, 0);
        Children.Add(header);

        var scroll = Scroll(_list);
        SetRow(scroll, 1);
        Children.Add(scroll);
        var footer = new Border { Child = _user, BorderBrush = Brush(Alpha(Microsoft.UI.Colors.Black, 0.06)), BorderThickness = new Thickness(0, 1, 0, 0) };
        SetRow(footer, 2);
        Children.Add(footer);

        shell.Sessions.Changed += () => DispatcherQueue.TryEnqueue(Render);
        App.Session.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(Render);
        Render();
    }

    User? SignedInUser => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User : null;

    public void Render()
    {
        _list.Children.Clear();
        var nav = new StackPanel { Spacing = 2 };
        foreach (var section in WorkspaceSections.Sidebar) nav.Children.Add(NavRow(section));
        _list.Children.Add(nav);
        if (SignedInUser is not null) { Group("pin"); Group("recent"); }
        else { _list.Children.Add(GroupHeader("recent", "最近对话")); _list.Children.Add(Muted("登录后读取对话")); }
        _user.Child = UserEntry();
        if ((SignedInUser?.Id ?? "") != _tierAccount) _ = LoadTierAsync();
    }

    async Task LoadTierAsync()
    {
        var account = _tierAccount = SignedInUser?.Id ?? "";
        _tier = null;
        if (account.Length == 0) return;
        try
        {
            var summary = BillingSummary.From(await App.Session.Api.CareerRequestAsync("/api/billing/summary"));
            if (account != _tierAccount) return;
            _tier = summary.TierLabel;
            _user.Child = UserEntry();
        }
        catch { }
    }

    /// <summary>NavigationViewItem：224×36、圆角 4、左 12；图标 16 #55554F、文字 13；选中 #E6E6E2 底 500 字 + 左侧 3×16 墨黑指示条，悬停 4% 黑。</summary>
    UIElement NavRow(WorkspaceSection section)
    {
        var active = _shell.Selection == section && (section != WorkspaceSection.Assistant);
        var label = HStack(12,
            new FontIcon { Glyph = section.Glyph(), FontSize = 15, FontFamily = IconFamily, Foreground = Brush(Sub), Width = 16 },
            Label(section.Title(), 13, Txt, active ? Medium : Regular));
        var indicator = new Border { Width = 3, Height = 16, CornerRadius = new CornerRadius(1.5), Background = Brush(Txt), HorizontalAlignment = HorizontalAlignment.Left, Visibility = active ? Visibility.Visible : Visibility.Collapsed };
        var row = new Grid { Height = 36, CornerRadius = new CornerRadius(4), Background = Brush(active ? Hl : Clear) };
        row.Children.Add(label.Pad(12, 0, 8, 0));
        row.Children.Add(indicator);
        if (!active) row.OnHover(h => row.Background = Brush(h ? Alpha(Microsoft.UI.Colors.Black, 0.04) : Clear));
        row.OnTap(() => _shell.Select(section), section.Title());
        return row;
    }

    void Group(string key)
    {
        var label = key == "pin" ? "置顶" : "最近对话";
        var items = _shell.Sessions.Items.Where(x => x.Bool("pinned") == (key == "pin")).ToList();
        if (key != "recent" && items.Count == 0) return;
        _list.Children.Add(GroupHeader(key, label));
        if (_collapsed.Contains(key)) return;
        var rows = new StackPanel { Spacing = 2 };
        switch (_shell.Sessions.Status)
        {
            case AgentSessions.LoadStatus.Loading or AgentSessions.LoadStatus.Idle: rows.Children.Add(Muted("正在读取对话…")); break;
            case AgentSessions.LoadStatus.Error: rows.Children.Add(Muted("对话列表暂时无法读取")); break;
            default:
                if (items.Count == 0) rows.Children.Add(Muted(key == "pin" ? "还没有置顶对话" : "还没有对话"));
                var limit = key == "pin" || _showAll ? 30 : 5;
                foreach (var item in items.Take(limit)) rows.Children.Add(SessionRow(item));
                if (key == "recent" && items.Count > 5)
                    rows.Children.Add(Label(_showAll ? "收起" : "查看全部", 13, Fnt).Pad(12, 0, 0, 0).Frame(height: 32)
                        .Also(x => x.Padding = new Thickness(0, 6, 0, 0)).OnTap(() => { _showAll = !_showAll; Render(); }));
                break;
        }
        _list.Children.Add(rows);
    }

    /// <summary>NavigationViewItemHeader：上 20、28 高、左 12；12px #6C6C65 标题 + 折叠箭头；「最近对话」右侧常显「✎ 新对话」。</summary>
    UIElement GroupHeader(string key, string label)
    {
        var collapsed = _collapsed.Contains(key);
        void Toggle() { if (!_collapsed.Remove(key)) _collapsed.Add(key); Render(); }
        var toggle = HStack(4, Label(label, 12, Fnt), Icon(collapsed ? "chevron.right" : "chevron.down", 9, Fnt)).OnTap(Toggle, collapsed ? $"展开{label}" : $"收起{label}");
        toggle.Background = Brush(Clear);
        UIElement right = new Border();
        if (key == "recent")
        {
            var create = HStack(4, Icon("square.and.pencil", 12, Fnt), Label("新对话", 12, Fnt));
            var button = new Border { Child = create, Padding = new Thickness(6, 0, 6, 0), Height = 22, CornerRadius = new CornerRadius(4), Background = Brush(Clear) }
                .Tip("新建对话 (Ctrl+N)");
            button.OnHover(h => button.Background = Brush(h ? Alpha(Microsoft.UI.Colors.Black, 0.05) : Clear));
            button.OnTap(() => { if (SignedInUser is null) _ = _shell.RequestLoginAsync(reason: "登录后开始对话。"); else _shell.NewChat(); }, "新建对话");
            right = button;
        }
        var row = Spread(toggle, right, 0);
        row.Height = 28;
        row.Margin = new Thickness(0, 20, 0, 2);
        row.Padding = new Thickness(12, 0, 2, 0);
        return row;
    }

    static TextBlock Muted(string text) => Label(text, 12, Side).Pad(12, 4, 12, 4);

    /// <summary>
    /// NavigationViewItem / Session：224×32、圆角 4、左 12 右 36 留给 ⋯；13px 墨色字，当前项 #E6E6E2 底（无指示条），悬停 4% 黑。
    /// 右键或 ⋯ 打开 MenuFlyout（置顶、重命名 F2、删除）；重命名时变成输入框，Enter 保存、Esc 取消。
    /// </summary>
    UIElement SessionRow(JsonNode item)
    {
        var id = item.Text("id");
        var title = item.Text("title") is { Length: > 0 } t ? t : "新对话";
        var pinned = item.Bool("pinned");
        var active = _shell.Selection == WorkspaceSection.Assistant && _shell.ActiveChatId == id;
        if (_renaming == id) return RenameBox(id, title);

        var text = Label(title, 13, Txt, active ? Medium : Regular).Pad(12, 0, 36, 0).Align(v: VerticalAlignment.Center);
        ToolTipService.SetToolTip(text, title);
        var more = new V3IconButton("ellipsis", $"{title} 的更多操作", () => { }, 24, 12, Fnt) { Opacity = 0 };
        more.HorizontalAlignment = HorizontalAlignment.Right;
        more.VerticalAlignment = VerticalAlignment.Center;
        more.Margin = new Thickness(0, 0, 6, 0);
        var row = new Grid { Height = 32, CornerRadius = new CornerRadius(4), Background = Brush(active ? Hl : Clear) };
        row.Children.Add(text);
        row.Children.Add(more);
        row.OnHover(h => { more.Opacity = h ? 1 : 0; if (!active) row.Background = Brush(h ? Alpha(Microsoft.UI.Colors.Black, 0.04) : Clear); });
        row.PointerReleased += (_, e) => { if (e.OriginalSource is not FrameworkElement source || !IsInside(source, more)) _shell.OpenChat(id); };

        MenuFlyout Menu()
        {
            var menu = new MenuFlyout();
            var pin = new MenuFlyoutItem { Text = pinned ? "取消置顶" : "置顶", Icon = new FontIcon { Glyph = Icons.Glyph("pin") } };
            pin.Click += async (_, _) =>
            {
                try { await _shell.Sessions.SetPinnedAsync(App.Session.Api, id, !pinned); }
                catch { await V3Dialog.AlertAsync(XamlRoot, "置顶状态保存失败，请重试"); }
            };
            var rename = new MenuFlyoutItem { Text = "重命名", Icon = new FontIcon { Glyph = Icons.Glyph("pencil") }, KeyboardAcceleratorTextOverride = "F2" };
            rename.Click += (_, _) => { _renaming = id; Render(); };
            var delete = new MenuFlyoutItem { Text = "删除", Icon = new FontIcon { Glyph = Icons.Glyph("trash") }, Foreground = Brush(Red), IsEnabled = !_shell.Sessions.RunningIds.Contains(id), KeyboardAcceleratorTextOverride = "Del" };
            delete.Click += (_, _) => ConfirmDelete(id, title);
            menu.Items.Add(pin);
            menu.Items.Add(rename);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(delete);
            return menu;
        }
        more.PointerReleased += (_, e) => { e.Handled = true; Menu().ShowAt(more); };
        row.ContextFlyout = Menu();
        return row;
    }

    static bool IsInside(DependencyObject node, DependencyObject target)
    {
        for (var current = node; current is not null; current = VisualTreeHelper.GetParent(current))
            if (current == target) return true;
        return false;
    }

    UIElement RenameBox(string id, string title)
    {
        var box = Input("", title, 120).Tip($"重命名对话 {title}");
        box.BorderBrush = Brush(Txt);
        var done = false;
        void Save()
        {
            if (done) return;
            done = true;
            var value = box.Text.Trim();
            _renaming = null;
            Render();
            if (value.Length > 0 && value != title) _ = _shell.Sessions.RenameAsync(App.Session.Api, id, value).ContinueWith(_ => { }, TaskScheduler.Default);
        }
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Save(); }
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; done = true; _renaming = null; Render(); }
        };
        box.LostFocus += (_, _) => Save();
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        return VStack(3, box, Label("Enter 保存 · Esc 取消", 12, Side).Pad(12, 2, 0, 3));
    }

    /// <summary>删除确认（稿 02B 14 · 01.1j）：ContentDialog「删除这条对话？」，说明含会话名与“此操作无法撤销”。</summary>
    void ConfirmDelete(string id, string title)
    {
        V3Overlay.Show(XamlRoot, close =>
        {
            V3Button? remove = null;
            remove = new V3Button("删除", async () =>
            {
                remove!.Enabled = false;
                remove.Title = "正在删除…";
                try { await _shell.Sessions.DeleteAsync(App.Session.Api, id); _shell.ChatDeleted(id); close(); }
                catch { remove.Enabled = true; remove.Title = "删除"; }
            }, V3Button.Kind.Danger);
            return V3Dialog.Make(V3DialogHead.Make("删除这条对话？", $"「{title}」及其中的全部消息将被永久删除。此操作无法撤销。"),
                [new V3Button("取消", close), remove], close);
        });
    }

    /// <summary>账户行：56 高、左右 16；PersonPicture 24、名字 13/500、「· 档位」12 灰、右侧上下箭头。游客显示「游客模式 · 登录」。</summary>
    UIElement UserEntry()
    {
        Grid Row(UIElement avatar, string name, string? trailing, bool chevron)
        {
            var grid = new Grid { Height = 56, Padding = new Thickness(16, 0, 16, 0), ColumnSpacing = 10, Background = Brush(Clear) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(((FrameworkElement)avatar).Align(v: VerticalAlignment.Center));
            var label = HStack(6, Label(name, 13, Txt, Medium), trailing is null ? null : Label(trailing, 12, Fnt));
            SetColumn(label, 1);
            grid.Children.Add(label);
            if (chevron) { var c = Icon("chevron.up.chevron.down", 12, Side).Align(v: VerticalAlignment.Center); SetColumn(c, 2); grid.Children.Add(c); }
            grid.OnHover(h => grid.Background = Brush(h ? Alpha(Microsoft.UI.Colors.Black, 0.04) : Clear));
            return grid;
        }
        if (SignedInUser is not { } user)
        {
            var guest = new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(12), Background = Brush(Txt), Child = Label("我", 11, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
            return Row(guest, "游客模式", "· 登录", false).OnTap(() => _ = _shell.RequestLoginAsync(), "登录或恢复登录");
        }
        var name = user.Nickname.Length > 0 ? user.Nickname : user.Email ?? "我";
        var row = Row(new UserAvatar(user, 24), name, _tier is null ? null : $"· {_tier}", true);
        if (_shell.Selection == WorkspaceSection.Account) row.Background = Brush(Alpha(Microsoft.UI.Colors.Black, 0.05));
        return row.OnTap(() =>
        {
            Flyout? flyout = null;
            var menu = new UserMenu(user,
                () => { flyout?.Hide(); _shell.OpenPlans(); },
                () => { flyout?.Hide(); _shell.OpenCareerProfile(); },
                () => { flyout?.Hide(); _shell.Select(WorkspaceSection.Account); },
                () => flyout?.Hide());
            flyout = V3Popover.Show(row, menu, FlyoutPlacementMode.TopEdgeAlignedLeft, 8);
        }, $"打开个人菜单，当前账号：{name}");
    }
}

/// <summary>
/// 个人菜单（稿 01 页 03.01，与线上一致）：288 宽；头部头像 36、名称 16/500、档位 12 靠右，下边线；
/// 我的额度（右侧积分，用完红色）、求职画像、个人设置、退出登录。条目 40 高、14/500、16 号图标，悬停 #F4F4F2。
/// </summary>
public sealed class UserMenu : StackPanel
{
    readonly TextBlock _tier = Label("", 12, Sub);
    readonly TextBlock _credits = Label("—", 13, Sub);
    bool _loggingOut;

    public UserMenu(User user, Action openPlans, Action openCareerProfile, Action openAccount, Action close)
    {
        Width = 288 - 16;
        var name = Label(user.Nickname.Length > 0 ? user.Nickname : user.Email ?? "我", 16, Txt, Medium);
        Children.Add(new Border
        {
            Padding = new Thickness(8, 8, 8, 16), Margin = new Thickness(0, 0, 0, 4), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1),
            Child = Columns(12, (Auto, new UserAvatar(user, 36)), (Star(), name.Align(v: VerticalAlignment.Center)), (Auto, _tier.Align(v: VerticalAlignment.Center))),
        });
        Children.Add(Item("我的额度", "gauge.with.dots.needle.33percent", openPlans, _credits));
        Children.Add(Item("求职画像", "person.text.rectangle", openCareerProfile));
        Children.Add(Item("个人设置", "gearshape", openAccount));
        Children.Add(Divider().Pad(6, 4, 6, 4));
        TextBlock? logoutLabel = null;
        var logout = Item("退出登录", "rectangle.portrait.and.arrow.right", () =>
        {
            if (_loggingOut) return;
            _loggingOut = true;
            logoutLabel!.Text = "正在退出…";
            close();
            _ = App.Session.SignOutCommand.ExecuteAsync(null);
        });
        logoutLabel = ((logout.Child as Grid)!.Children[1] as TextBlock)!;
        Children.Add(logout);
        Loaded += async (_, _) =>
        {
            try
            {
                var summary = BillingSummary.From(await App.Session.Api.CareerRequestAsync("/api/billing/summary"));
                _tier.Text = summary.TierLabel;
                _credits.Text = $"{summary.AvailableText} 积分";
                _credits.Foreground = Brush(summary.Exhausted ? Red : Sub);
            }
            catch { }
        };
    }

    static Border Item(string title, string symbol, Action action, TextBlock? trailing = null)
    {
        var grid = Columns(10,
            (Px(16), Icon(symbol, 14, Txt)),
            (Star(), Label(title, 14, Txt, Medium).Align(v: VerticalAlignment.Center)),
            (Auto, (UIElement?)trailing?.Align(v: VerticalAlignment.Center) ?? new Border()));
        var row = new Border { Child = grid, MinHeight = 40, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(4), Background = Brush(Clear) };
        row.OnHover(h => row.Background = Brush(h ? Field : Clear));
        row.OnTap(action, title);
        return row;
    }
}

/// <summary>PersonPicture：默认头像（`/api/auth/default-avatar`）用随包 Logo，私有头像经桌面会话下载；没有时墨黑底白色首字。</summary>
public sealed class UserAvatar : BorderControl
{
    public UserAvatar(User user, double size)
    {
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size / 2);
        Background = Brush(Txt);
        var initial = (user.Nickname.Length > 0 ? user.Nickname : user.Email ?? "我")[..1];
        Child = Label(initial, size * 0.45, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Loaded += async (_, _) => await LoadAsync(user.AvatarUrl);
    }

    async Task LoadAsync(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        if (path.StartsWith("/api/auth/default-avatar", StringComparison.Ordinal))
        {
            Child = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/default-avatar.png")), Stretch = Stretch.UniformToFill };
            return;
        }
        if (App.Session.Api is not Core.Api.HttpApiClient client) return;
        try
        {
            var data = await client.Coordinator.AccountAvatarAsync(path);
            var bitmap = new BitmapImage();
            using var stream = new MemoryStream(data).AsRandomAccessStream();
            await bitmap.SetSourceAsync(stream);
            Child = new Image { Source = bitmap, Stretch = Stretch.UniformToFill };
        }
        catch { }
    }
}
