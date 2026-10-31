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
/// 工作区侧栏，对应 Mac `Shell/Sidebar.swift`（Web `v3/Shell.tsx` 的 `V3Sidebar`）：品牌与公告铃、8 项导航、
/// 置顶与最近对话分组、对话行 ⋯ 菜单（置顶、重命名、删除）和底部个人菜单。宽 216、左右内边距 14。
/// </summary>
public sealed class Sidebar : Grid
{
    readonly WorkspaceShell _shell;
    readonly StackPanel _list = new();
    readonly Border _user = new();
    readonly HashSet<string> _collapsed = [];
    string? _renaming;

    public Sidebar(WorkspaceShell shell)
    {
        _shell = shell;
        Width = 216;
        Padding = new Thickness(14, 0, 14, 0);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = Star() });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var brand = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/wordmark.png")), Width = 146, Height = 30, Stretch = Stretch.Uniform }.Tip("DrawOffer 首页");
        brand.PointerReleased += (_, _) => _shell.Select(WorkspaceSection.Home);
        var header = Spread(brand, new AnnouncementBell(shell));
        header.Margin = new Thickness(8, 24, 0, 22);
        Children.Add(header);

        var scroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
        SetRow(scroll, 1);
        Children.Add(scroll);
        _user.Margin = new Thickness(0, 8, 0, 20);
        SetRow(_user, 2);
        Children.Add(_user);

        shell.Sessions.Changed += Render;
        App.Session.PropertyChanged += (_, _) => Render();
        Render();
    }

    User? SignedInUser => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User : null;

    public void Render()
    {
        _list.Children.Clear();
        var nav = new StackPanel { Spacing = 4 };
        foreach (var section in WorkspaceSections.Sidebar) nav.Children.Add(NavRow(section));
        _list.Children.Add(nav);
        if (SignedInUser is not null) { Group("pin"); Group("recent"); }
        else { _list.Children.Add(GroupHeader("recent", "最近对话")); _list.Children.Add(Muted("登录后读取对话")); }
        _user.Child = UserEntry();
    }

    /// <summary>导航行：34 高、圆角 8、14px；当前项 #E6E6E2 底、500 字重、#1D1D1B，其余 #55554F。</summary>
    UIElement NavRow(WorkspaceSection section)
    {
        var active = _shell.Selection == section && (section != WorkspaceSection.Home || _shell.ActiveChatId is null);
        var color = active ? Txt : Sub;
        var label = HStack(10, new FontIcon { Glyph = section.Glyph(), FontSize = 14, FontFamily = IconFamily, Foreground = Brush(color) },
            Label(section.Title(), 14, color, active ? Medium : Regular));
        var row = new Border { Child = label, Height = 34, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(8), Background = Brush(active ? Hl : Clear) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, section.Title());
        if (!active)
        {
            row.PointerEntered += (_, _) => row.Background = Brush(Field);
            row.PointerExited += (_, _) => row.Background = Brush(Clear);
        }
        row.PointerReleased += (_, _) => _shell.Select(section);
        return row;
    }

    void Group(string key)
    {
        var label = key == "pin" ? "置顶" : "最近对话";
        var items = _shell.Sessions.Items.Where(x => x.Bool("pinned") == (key == "pin")).ToList();
        if (key != "recent" && items.Count == 0) return;
        _list.Children.Add(GroupHeader(key, label));
        if (_collapsed.Contains(key)) return;
        var rows = new StackPanel { MinHeight = 40 }; // Web `.v3-side-sessions { min-height: 40px }`
        switch (_shell.Sessions.Status)
        {
            case AgentSessions.LoadStatus.Loading or AgentSessions.LoadStatus.Idle: rows.Children.Add(Muted("正在读取对话…")); break;
            case AgentSessions.LoadStatus.Error: rows.Children.Add(Muted("对话列表暂时无法读取")); break;
            default:
                if (items.Count == 0) rows.Children.Add(Muted(key == "pin" ? "还没有置顶对话" : "还没有对话"));
                foreach (var item in key == "pin" ? items : items.Take(30)) rows.Children.Add(SessionRow(item));
                break;
        }
        _list.Children.Add(rows);
    }

    /// <summary>
    /// Web `.v3-side-section`：外边距 22/12/8，12px #6C6C65；置顶标题在左、18×18 折叠钮在右；
    /// 最近对话的折叠钮带文字（13px），新建对话只在悬停这一行时出现。
    /// </summary>
    UIElement GroupHeader(string key, string label)
    {
        var collapsed = _collapsed.Contains(key);
        void Toggle() { if (!_collapsed.Remove(key)) _collapsed.Add(key); Render(); }
        FontIcon Chevron() => Icon(collapsed ? "chevron.right" : "chevron.down", 9, Fnt);
        Grid row;
        if (key == "pin")
        {
            var toggle = SideIcon(Chevron(), Toggle).Tip(collapsed ? $"展开{label}" : $"收起{label}");
            row = Spread(Label(label, 12, Fnt), toggle, 0);
        }
        else
        {
            var toggle = HStack(5, Label(label, 13, Fnt), Chevron()).Frame(height: 18).Tip(collapsed ? $"展开{label}" : $"收起{label}");
            toggle.Background = Brush(Clear);
            toggle.PointerReleased += (_, _) => Toggle();
            var create = SideIcon(Icon("square.and.pencil", 12, Fnt), _shell.NewChat).Tip("新建对话");
            create.Opacity = 0; // 与 Web 一样悬停才显示；保留在可视树里，键盘与读屏仍能找到它
            row = Spread(toggle, create, 0);
            row.Background = Brush(Clear);
            row.PointerEntered += (_, _) => create.Opacity = 1;
            row.PointerExited += (_, _) => create.Opacity = 0;
        }
        row.MinHeight = 18;
        row.Margin = new Thickness(12, 22, 12, 8);
        return row;
    }

    static TextBlock Muted(string text) => Label(text, 12, Fnt).Pad(12, 4, 12, 4);

    /// <summary>侧栏 18×18 小图标钮：悬停 #F4F4F2 底、圆角 5。</summary>
    static Border SideIcon(FontIcon icon, Action action)
    {
        var button = new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(5), Background = Brush(Clear), Child = icon.Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
        button.PointerEntered += (_, _) => { button.Background = Brush(Field); icon.Foreground = Brush(Txt); };
        button.PointerExited += (_, _) => { button.Background = Brush(Clear); icon.Foreground = Brush(Fnt); };
        button.PointerReleased += (_, e) => { e.Handled = true; action(); };
        return button;
    }

    /// <summary>
    /// 对话行（Web `.v3-side-session`）：198×32、14px、左 12 右 36 留给 ⋯（距右 6）；悬停 #F4F4F2，当前 #E6E6E2。
    /// 重命名时变成 198×32 输入框（圆角 7、深色边），下方“Enter 保存 · Esc 取消”。
    /// </summary>
    UIElement SessionRow(JsonNode item)
    {
        var id = item.Text("id");
        var title = item.Text("title") is { Length: > 0 } t ? t : "新对话";
        var pinned = item.Bool("pinned");
        var active = _shell.Selection == WorkspaceSection.Assistant && _shell.ActiveChatId == id;
        if (_renaming == id) return RenameBox(id, title);

        var text = Label(title, 14, active ? Txt : Sub, active ? Medium : Regular).Pad(12, 0, 36, 0).Align(v: VerticalAlignment.Center);
        ToolTipService.SetToolTip(text, title);
        var more = new Border { Width = 24, Height = 24, Child = Icon("ellipsis", 12, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = 0, Margin = new Thickness(0, 0, 6, 0) }
            .Align(HorizontalAlignment.Right, VerticalAlignment.Center).Tip($"{title} 的更多操作");
        var row = new Grid { Width = 198, Height = 32, CornerRadius = new CornerRadius(8), Background = Brush(active ? Hl : Clear) };
        row.Children.Add(text);
        row.Children.Add(more);
        row.PointerEntered += (_, _) => { more.Opacity = 1; text.Foreground = Brush(Txt); if (!active) row.Background = Brush(Field); };
        row.PointerExited += (_, _) => { more.Opacity = 0; text.Foreground = Brush(active ? Txt : Sub); if (!active) row.Background = Brush(Clear); };
        row.PointerReleased += (_, e) => { if (e.OriginalSource is not FrameworkElement source || !IsInside(source, more)) _shell.OpenChat(id); };

        MenuFlyout Menu()
        {
            var menu = new MenuFlyout();
            var pin = new MenuFlyoutItem { Text = pinned ? "取消置顶" : "置顶" };
            pin.Click += async (_, _) =>
            {
                try { await _shell.Sessions.SetPinnedAsync(App.Session.Api, id, !pinned); }
                catch { await Alert("置顶状态保存失败，请重试"); }
            };
            var rename = new MenuFlyoutItem { Text = "重命名" };
            rename.Click += (_, _) => { _renaming = id; Render(); };
            var delete = new MenuFlyoutItem { Text = "删除", Foreground = Brush(Red), IsEnabled = !_shell.Sessions.RunningIds.Contains(id) };
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
        var box = new TextBox
        {
            Text = title, MaxLength = 120, FontSize = 14, Width = 198, Height = 32, MinHeight = 0, Padding = new Thickness(12, 6, 12, 0),
            CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1), BorderBrush = Brush(Txt), Background = Brush(V3.White),
        }.Tip($"重命名对话 {title}");
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
        return VStack(3, box, Label("Enter 保存 · Esc 取消", 12, Fnt).Pad(12, 2, 0, 3));
    }

    /// <summary>删除确认（Mac `confirmationDialog`）：标题“删除这条对话？”、说明含会话名与“此操作无法撤销”。</summary>
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
            }, V3Button.Kind.Danger, height: 36);
            return V3Dialog.Make(V3DialogHead.Make("删除这条对话？", $"「{title}」及其中的全部消息将被永久删除。\n此操作无法撤销。"),
                [new V3Button("取消", close, height: 36), remove], close, width: 420);
        });
    }

    async Task Alert(string message)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = message, CloseButtonText = "知道了" };
        await dialog.ShowAsync();
    }

    /// <summary>
    /// 底部账号入口（Web `.v3-side-user`）：最小 44 高、内边距 0/6、间距 8、圆角 8；名称 14/500 行高 20，邮箱 12 行高 18（最宽 130）。
    /// 游客显示“我”头像与“游客模式 / 登录 / 恢复登录”。
    /// </summary>
    UIElement UserEntry()
    {
        if (SignedInUser is not { } user)
        {
            var guest = HStack(8,
                new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = Brush(0x17191C), Child = Label("我", 14, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) },
                VStack(3, Label("游客模式", 13.5, Txt, Medium), Label("登录 / 恢复登录", 11, Hex(0x96968F))));
            guest.Margin = new Thickness(6, 0, 6, 0);
            guest.Background = Brush(Clear);
            guest.PointerReleased += (_, _) => _ = _shell.RequestLoginAsync();
            return guest;
        }
        var name = user.Nickname.Length > 0 ? user.Nickname : "未设置昵称";
        var row = new Border
        {
            MinHeight = 44, Padding = new Thickness(6, 0, 6, 0), CornerRadius = new CornerRadius(8),
            Background = Brush(_shell.Selection == WorkspaceSection.Account ? Hl : Clear),
            Child = HStack(8, new UserAvatar(user, 36), VStack(0,
                Label(name, 14, Txt, Medium).Frame(height: 20),
                Label(user.Email ?? "微信登录", 12, Fnt).Frame(height: 18).Also(x => x.MaxWidth = 130))),
        }.Tip($"打开个人菜单，当前账号：{(user.Nickname.Length > 0 ? user.Nickname : user.Email ?? "我")}");
        row.PointerEntered += (_, _) => { if (_shell.Selection != WorkspaceSection.Account) row.Background = Brush(Field); };
        row.PointerExited += (_, _) => row.Background = Brush(_shell.Selection == WorkspaceSection.Account ? Hl : Clear);
        row.PointerReleased += (_, _) =>
        {
            Flyout? flyout = null;
            var menu = new UserMenu(user, () => { flyout?.Hide(); _shell.OpenPlans(); }, () => { flyout?.Hide(); _shell.Select(WorkspaceSection.Account); }, () => flyout?.Hide());
            flyout = V3Popover.Show(row, menu, FlyoutPlacementMode.Top, 8);
        };
        return row;
    }
}

/// <summary>
/// 个人菜单（Web `SidebarUserMenu` / `.bill-user-menu`），对应 Mac `UserMenu`：288 宽、内边距 8；
/// 头部 8/8/16 带下边线（头像 36、名称 16/500、档位 12 靠右），菜单项 40 高、14/500、16 号图标。
/// </summary>
public sealed class UserMenu : StackPanel
{
    readonly TextBlock _tier = Label("", 12, Sub);
    readonly TextBlock _credits = Label("—", 14, Sub, Medium);
    bool _loggingOut;

    public UserMenu(User user, Action openPlans, Action openAccount, Action close)
    {
        Width = 288 - 16; // Flyout 内边距 8 已计入
        var name = Label(user.Nickname.Length > 0 ? user.Nickname : user.Email ?? "我", 16, Txt, Medium);
        var head = new Border
        {
            Padding = new Thickness(8, 8, 8, 16), Margin = new Thickness(0, 0, 0, 4), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1),
            Child = Columns(12, (Auto, new UserAvatar(user, 36)), (Star(), name.Align(v: VerticalAlignment.Center)), (Auto, _tier.Align(v: VerticalAlignment.Center))),
        };
        Children.Add(head);
        Children.Add(Item("我的额度", "", openPlans, _credits));
        Children.Add(Item("个人设置", "", openAccount));
        Children.Add(Divider().Pad(6, 4, 6, 4));
        TextBlock? logoutLabel = null;
        var logout = Item("退出登录", "", () =>
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
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Children[1], $"我的额度, {summary.AvailableText} 积分");
            }
            catch { }
        };
    }

    /// <summary>`.v3-menu-item`：最小 40 高、内边距 8/10、间距 10、14/500；悬停 #F4F4F2、圆角 6。图标为 Fluent（Mac 为 gauge / gearshape / rectangle.portrait.and.arrow.right）。</summary>
    static Border Item(string title, string glyph, Action action, TextBlock? trailing = null)
    {
        var grid = Columns(10,
            (Px(16), new FontIcon { Glyph = glyph, FontSize = 13, FontFamily = IconFamily, Foreground = Brush(Txt) }),
            (Star(), Label(title, 14, Txt, Medium).Align(v: VerticalAlignment.Center)),
            (Auto, (UIElement?)trailing?.Align(v: VerticalAlignment.Center) ?? new Border()));
        var row = new Border { Child = grid, MinHeight = 40, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(6), Background = Brush(Clear) }.Tip(title);
        row.PointerEntered += (_, _) => row.Background = Brush(Field);
        row.PointerExited += (_, _) => row.Background = Brush(Clear);
        row.PointerReleased += (_, _) => action();
        return row;
    }
}

/// <summary>头像，对应 Mac `UserAvatar`：默认头像（`/api/auth/default-avatar`）用随包 Logo，私有头像经桌面会话下载；没有时显示名字首字。</summary>
public sealed class UserAvatar : DrawOffer.App.DesignSystem.BorderControl
{
    public UserAvatar(User user, double size)
    {
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(size / 2);
        Background = Brush(0x17191C);
        var initial = (user.Nickname.Length > 0 ? user.Nickname : user.Email ?? "我")[..1];
        Child = Label(initial, size * 0.4, V3.White, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Loaded += async (_, _) => await LoadAsync(user.AvatarUrl);
    }

    async Task LoadAsync(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        if (path.StartsWith("/api/auth/default-avatar", StringComparison.Ordinal))
        {
            Child = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/DrawOffer.png")), Stretch = Stretch.UniformToFill };
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


