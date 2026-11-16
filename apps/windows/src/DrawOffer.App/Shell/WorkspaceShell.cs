using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>
/// 工作区外壳（Windows 稿 00 页「窗口模板」6:959）：单层窗口——左侧 248 宽侧栏贴边到顶，中间 1px #ECECEA 分隔线，
/// 右侧白色内容区铺满，不再嵌圆角卡片。内容区顶部 48 是标题栏拖动区（右上角系统最小化/最大化/关闭）。
/// 编辑器、模拟面试场次用 <see cref="Bare"/> 隐藏侧栏，页面自己画 TitleBar / CommandBar 并用 <see cref="SetDragRegion"/> 指定拖动区。
/// 游客（未登录）只能看首页，点其他入口留在原处并打开整窗登录页（稿 01 页 02）。
/// </summary>
public sealed class WorkspaceShell : Grid
{
    public static WorkspaceShell Current { get; private set; } = null!;
    public const double TitleBarHeight = 48;

    public AgentSessions Sessions { get; } = new();
    public AnnouncementCenter Announcements { get; } = new();
    public WorkspaceSection Selection { get; private set; } = WorkspaceSection.Home;
    public string? ActiveChatId { get; private set; }

    readonly Sidebar _sidebar;
    readonly Border _divider = new() { Width = 1, Background = Brush(Line) };
    readonly Grid _main = new() { Background = Brush(V3.White) };
    readonly Border _strip = new() { Height = TitleBarHeight, Background = Brush(Clear), VerticalAlignment = VerticalAlignment.Top };
    readonly StackPanel _banner = new();
    readonly ContentControl _content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    SignInView? _login;
    string? _accountId;
    /// <summary>当前对话：sessionId 为空表示新对话，initial 是首页带过来的第一条消息；token 变化时重建对话页。</summary>
    (string? sessionId, string? initial, string? model, string? draft, Guid token)? _chat;
    /// <summary>首页“带着它去练”带过去的练习重点（模拟面试首页读取后清空）。</summary>
    public object? MockFocus { get; set; }
    /// <summary>首页点开某一场模拟面试（面试纸 / 报告纸）。</summary>
    public string? MockSession { get; set; }
    /// <summary>要直接打开编辑器的简历。</summary>
    public string? PendingEditResume { get; set; }
    /// <summary>“添加资料 / 导入简历”请求：我的简历页收到后打开导入。</summary>
    public Guid? ImportRequest { get; set; }
    /// <summary>登录前选中的示例模板 key：登录后回到模板页，按 key 匹配真实模板并打开创建弹窗。</summary>
    public string? PendingCreateKey { get; set; }
    /// <summary>从岗位广场 / 对话卡片打开的投递（投递看板读取后清空）。</summary>
    public string? PendingApplication { get; set; }
    /// <summary>个人菜单「求职画像」：账号页读取后切到求职画像。</summary>
    public bool CareerProfileRequested { get; set; }
    ResumeTemplate? _loginTemplate;
    bool _bare;

    public WorkspaceShell()
    {
        Current = this;
        Background = Brush(V3.White);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        _sidebar = new Sidebar(this);
        Children.Add(_sidebar);
        SetColumn(_divider, 1);
        Children.Add(_divider);

        _main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _main.RowDefinitions.Add(new RowDefinition { Height = Star() });
        _main.Children.Add(_strip);
        SetRow(_banner, 1);
        _main.Children.Add(_banner);
        SetRow(_content, 2);
        _main.Children.Add(_content);
        var toasts = new Grid { IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Top };
        SetRow(toasts, 2);
        _main.Children.Add(toasts);
        V3Toast.Host = toasts;
        SetColumn(_main, 2);
        Children.Add(_main);
        Layout();

        App.Session.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(SessionViewModel.Phase) or nameof(SessionViewModel.User) or nameof(SessionViewModel.ErrorMessage))
                DispatcherQueue.TryEnqueue(OnSessionChanged);
        };
        Loaded += (_, _) => { OnSessionChanged(); SetDragRegion(null); };
        KeyboardAccelerators.Add(Accelerator(Windows.System.VirtualKey.N, () => { if (SignedInUser is not null) NewChat(); }));
    }

    static Microsoft.UI.Xaml.Input.KeyboardAccelerator Accelerator(Windows.System.VirtualKey key, Action action)
    {
        var accelerator = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = key, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        accelerator.Invoked += (_, e) => { e.Handled = true; action(); };
        return accelerator;
    }

    /// <summary>编辑器与模拟面试场次不显示侧栏（Web `V3Shell bare`），也不留 48 高的空标题栏行，页面自己画。</summary>
    public bool Bare
    {
        get => _bare;
        set { _bare = value; Layout(); }
    }

    void Layout()
    {
        var hide = _bare || _login is not null;
        _sidebar.Visibility = _bare ? Visibility.Collapsed : Visibility.Visible;
        _divider.Visibility = _bare ? Visibility.Collapsed : Visibility.Visible;
        _strip.Visibility = _bare ? Visibility.Collapsed : Visibility.Visible;
        if (!hide) SetDragRegion(null);
    }

    /// <summary>
    /// 指定窗口拖动区（标题栏）：传 null 恢复为内容区顶部 48 的空白条；无侧栏页面传自己 CommandBar 里的空白区域。
    /// </summary>
    public void SetDragRegion(FrameworkElement? region)
    {
        if (App.NativeWindow is MainWindow window) window.SetDragRegion(region ?? (_bare ? null : _strip));
    }

    User? SignedInUser => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User : null;

    void OnSessionChanged()
    {
        var user = SignedInUser;
        // 先取出登录页携带的模板：关闭登录页会清空它
        var template = user is not null ? _loginTemplate : null;
        if (user is not null) { _loginTemplate = null; CloseLogin(); }
        if (_accountId != user?.Id)
        {
            // 退出或换账号：清空对话、草稿和弹窗，回到首页
            if (_accountId is not null)
            {
                V3Overlay.CloseAll();
                ActiveChatId = null; _chat = null; PendingEditResume = null; PendingCreateKey = null; PendingApplication = null;
                MockFocus = null; MockSession = null; CareerProfileRequested = false; Selection = WorkspaceSection.Home; _bare = false;
            }
            if (user is null) { Selection = WorkspaceSection.Home; _bare = false; }
            _accountId = user?.Id;
            Announcements.Reset(user?.Id ?? "");
            _ = RefreshAccountDataAsync(user?.Id ?? "");
        }
        if (template is not null) { PendingCreateKey = template.Key; Selection = WorkspaceSection.Templates; _bare = false; }
        Layout();
        RenderBanner();
        _sidebar.Render();
        ShowSection();
    }

    async Task RefreshAccountDataAsync(string account)
    {
        await Sessions.LoadAsync(App.Session.Api, account);
        await Announcements.RefreshAsync(App.Session.Api);
        Announcements.AutoOpenImportant(App.Session.Api);
        if (Announcements.Detail is not null) AnnouncementDetail.Show(this);
    }

    /// <summary>窗口重新激活时刷新公告。</summary>
    public async void OnActivated()
    {
        await Announcements.RefreshAsync(App.Session.Api);
        Announcements.AutoOpenImportant(App.Session.Api);
        if (Announcements.Detail is not null) AnnouncementDetail.Show(this);
    }

    /// <summary>登录恢复失败等常驻提示：InfoBar（Warning，不可关闭），恢复中时带「重试恢复」。</summary>
    void RenderBanner()
    {
        _banner.Children.Clear();
        if (App.Session.ErrorMessage is not { } message || _login is not null) return;
        var retry = App.Session.Phase == SessionViewModel.SessionPhase.Restoring ? ("重试恢复", (Action)(() => _ = App.Session.RestoreAsync())) : ((string, Action)?)null;
        _banner.Children.Add(V3InfoBar.Make(V3InfoBar.Severity.Warning, message, null, null, retry).Pad(24, 0, 24, 8));
    }

    public void Select(WorkspaceSection section)
    {
        // 游客只开放首页：点其他入口留在原处，打开登录页
        if (SignedInUser is null && section != WorkspaceSection.Home)
        {
            _ = RequestLoginAsync(reason: section.Title());
            return;
        }
        Selection = section;
        if (section != WorkspaceSection.Resumes) PendingEditResume = null;
        if (section != WorkspaceSection.Assistant) ActiveChatId = null;
        if (section != WorkspaceSection.Account) CareerProfileRequested = false;
        Bare = false;
        _sidebar.Render();
        ShowSection();
    }

    public void Navigate(WorkspaceSection section) => Select(section);

    /// <summary>把一段文字放进新对话的输入框，等用户确认后再发送（截到 4000 字）。</summary>
    public void Draft(string text)
    {
        var info = new System.Globalization.StringInfo(text);
        var draft = info.LengthInTextElements <= 4000 ? text : info.SubstringByTextElements(0, 4000);
        if (SignedInUser is null) { _ = RequestLoginAsync(); return; }
        _chat = (null, null, null, draft, Guid.NewGuid());
        ActiveChatId = null;
        ShowChat();
    }

    public void OpenChat(string id)
    {
        _chat = (id, null, null, null, Guid.NewGuid());
        ActiveChatId = id;
        ShowChat();
    }

    /// <summary>发起新对话：带上第一条消息与选好的模型。</summary>
    public void StartChat(string text, string? model)
    {
        _chat = (null, text, model, null, Guid.NewGuid());
       
        ActiveChatId = null;
        ShowChat();
    }

    /// <summary>侧栏「新对话」（稿 02B·01 方案 A）：打开空白的新建对话页。</summary>
    public void NewChat()
    {
        _chat = (null, null, null, null, Guid.NewGuid());
        ActiveChatId = null;
        ShowChat();
    }

    void ShowChat()
    {
        Selection = WorkspaceSection.Assistant;
        Bare = false;
        _sidebar.Render();
        ShowSection();
    }

    public void ChatDeleted(string id)
    {
        if (ActiveChatId == id || _chat?.sessionId == id) { ActiveChatId = null; _chat = null; Select(WorkspaceSection.Home); }
    }

    /// <summary>新对话发出第一条后拿到会话 ID：侧栏高亮这一条。</summary>
    public void ChatCreated(string id)
    {
        ActiveChatId = id;
        ReloadSessions();
    }

    /// <summary>打开简历编辑器（铺满窗口、不显示侧栏）。</summary>
    public void EditResume(string id)
    {
        if (SignedInUser is null) { _ = RequestLoginAsync(); return; }
        PendingEditResume = id;
        Selection = WorkspaceSection.Resumes;
        ActiveChatId = null;
        Bare = true;
        _sidebar.Render();
        ShowSection();
    }

    void CloseEditor()
    {
        PendingEditResume = null;
        Select(WorkspaceSection.Resumes);
    }

    /// <summary>首页“带着它去练”。</summary>
    public void Practice(object? focus)
    {
        MockFocus = focus;
        Select(WorkspaceSection.Mock);
    }

    /// <summary>首页点开某一场模拟面试。</summary>
    public void OpenMockSession(string id)
    {
        MockSession = id;
        Select(WorkspaceSection.Mock);
    }

    /// <summary>打开某条投递的详情（岗位广场、对话卡片）。</summary>
    public void OpenApplication(string id)
    {
        PendingApplication = id;
        Select(WorkspaceSection.Jobs);
    }

    /// <summary>首页“选择文件”导入简历。</summary>
    public void RequestImport()
    {
        ImportRequest = Guid.NewGuid();
        Select(WorkspaceSection.Resumes);
    }

    public void OpenCareerProfile()
    {
        CareerProfileRequested = true;
        Selection = WorkspaceSection.Account;
        Bare = false;
        _sidebar.Render();
        _content.Content = null;
        ShowSection();
    }

    /// <summary>对话创建、删除、改名后刷新侧栏最近对话。</summary>
    public async void ReloadSessions()
    {
        await Sessions.LoadAsync(App.Session.Api, _accountId ?? "");
        _sidebar.Render();
    }

    /// <summary>生成中的对话不能删除（与 Web 一致）：对话页把生成状态回报给侧栏。</summary>
    public void SetRunning(string id, bool running)
    {
        if (running) Sessions.RunningIds.Add(id); else Sessions.RunningIds.Remove(id);
        _sidebar.Render();
    }

    public void OpenPlans() => PlansDialog.Show(this);

    void ShowSection()
    {
        var signedIn = SignedInUser is not null;
        // 昵称和头像更新会发布 User 变化；保留当前账号页及其编辑草稿。
        if (Selection == WorkspaceSection.Account && _content.Content is Views.Account.AccountPage) return;
        _content.Content = Selection switch
        {
            WorkspaceSection.Home when signedIn => new Views.Home.HomeMemoryView(),
            WorkspaceSection.Home => Views.Home.HomeMemoryView.Guest(() => _ = RequestLoginAsync(reason: "登录 DrawOffer，开始你的第一份简历。")),
            WorkspaceSection.Assistant when signedIn && _chat is { } chat => new Views.Assistant.AssistantChatView(chat.sessionId, chat.initial, chat.model, chat.draft),
            WorkspaceSection.Assistant when signedIn => new Views.Assistant.AssistantChatView(null, null, null, null),
            WorkspaceSection.Account when signedIn => new Views.Account.AccountPage(),
            WorkspaceSection.Datasets when signedIn => new DatasetLibraryPage(),
            WorkspaceSection.Mock when signedIn => new Views.Mock.MockInterviewView(this),
            WorkspaceSection.Schedule when signedIn => new Views.Career.InterviewScheduleView(),
            WorkspaceSection.Jobs when signedIn => new Views.Career.JobsBoardView(),
            WorkspaceSection.Opportunities when signedIn => new Views.JobPool.JobPoolView(OpenApplication),
            WorkspaceSection.Templates when signedIn => new TemplatesPage(),
            WorkspaceSection.Resumes when signedIn && PendingEditResume is { } edit => new Views.Resumes.ResumeEditorView(edit, CloseEditor),
            WorkspaceSection.Resumes when signedIn => new Views.Resumes.ResumesView(SignedInUser!.Id, () => Select(WorkspaceSection.Templates)),
            _ => Views.Home.HomeMemoryView.Guest(() => _ = RequestLoginAsync()),
        };
    }

    /// <summary>
    /// 需要登录时打开整窗登录页（稿 01 页 02，盖住侧栏，右上「暂不登录」回到游客模式）；已登录时提示「此功能尚未开放」。
    /// </summary>
    public async Task RequestLoginAsync(ResumeTemplate? template = null, string? reason = null)
    {
        if (SignedInUser is not null)
        {
            await V3Dialog.AlertAsync(XamlRoot, "此功能尚未开放", "此功能将在后续版本开放。你已输入的内容会保留。");
            return;
        }
        _loginTemplate = template;
        if (_login is not null) return;
        _login = new SignInView(() => { _loginTemplate = null; CloseLogin(); });
        SetColumnSpan(_login, 3);
        Children.Add(_login);
        RenderBanner();
        if (App.NativeWindow is MainWindow window) window.SetDragRegion(null);
    }

    void CloseLogin()
    {
        if (_login is null) return;
        Children.Remove(_login);
        _login = null;
        RenderBanner();
        SetDragRegion(null);
    }
}
