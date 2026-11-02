using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>
/// 工作区外壳，对应 Mac `Shell/WorkspaceView.swift`：#F1F1EF 底，左侧 216 宽侧栏，间隔 13，右侧白色内容卡
/// （圆角 16、1px #E4E4E0 边，上下右各留 12）。编辑器等铺满页面用 <see cref="Bare"/> 隐藏侧栏。
/// </summary>
public sealed class WorkspaceShell : Grid
{
    public static WorkspaceShell Current { get; private set; } = null!;

    public AgentSessions Sessions { get; } = new();
    public AnnouncementCenter Announcements { get; } = new();
    public WorkspaceSection Selection { get; private set; } = WorkspaceSection.Home;
    public string? ActiveChatId { get; private set; }

    readonly Sidebar _sidebar;
    readonly Border _card = new() { Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16) };
    readonly StackPanel _banner = new();
    readonly ContentControl _content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    V3Overlay? _login;
    string _homeDraft = "";
    string? _accountId;
    /// <summary>当前对话（Mac `ChatTarget`）：sessionID 为空表示新对话，initial 是首页带过来的第一条消息；token 变化时重建对话页。</summary>
    (string? sessionId, string? initial, string? model, Guid token)? _chat;
    /// <summary>首页“带着它去练”带过去的练习重点（Mac `mockFocus`）；模拟面试页移植后读取。</summary>
    public object? MockFocus { get; set; }
    /// <summary>要直接打开编辑器的简历（Mac `editResumeID`）；简历页移植后读取。</summary>
    public string? PendingEditResume { get; set; }
    /// <summary>“添加资料 / 导入简历”请求（Mac `importRequest`）；简历页移植后读取。</summary>
    public Guid? ImportRequest { get; set; }
    /// <summary>登录前选中的示例模板 key（Mac `pendingCreateKey`）：登录后回到模板页，按 key 匹配真实模板并打开创建弹窗。</summary>
    public string? PendingCreateKey { get; set; }
    /// <summary>登录弹窗携带的模板（Mac `loginRequest?.template`）。</summary>
    ResumeTemplate? _loginTemplate;
    bool _bare;

    public WorkspaceShell()
    {
        Current = this;
        Background = Brush(0xF1F1EF);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        _sidebar = new Sidebar(this);
        Children.Add(_sidebar);
        var inner = new Grid();
        inner.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        inner.RowDefinitions.Add(new RowDefinition { Height = Star() });
        inner.Children.Add(_banner);
        SetRow(_content, 1);
        inner.Children.Add(_content);
        _card.Child = inner;
        SetColumn(_card, 1);
        Children.Add(_card);
        Layout();

        App.Session.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(SessionViewModel.Phase) or nameof(SessionViewModel.User) or nameof(SessionViewModel.ErrorMessage)) OnSessionChanged();
        };
        Loaded += (_, _) => OnSessionChanged();
    }

    /// <summary>编辑器与模拟面试场次不显示侧栏（Web `V3Shell bare`）；编辑器还去掉内容卡的边距与圆角。</summary>
    public bool Bare
    {
        get => _bare;
        set { _bare = value; Layout(); }
    }

    void Layout()
    {
        var edge = _bare && Selection == WorkspaceSection.Resumes;
        _sidebar.Visibility = _bare ? Visibility.Collapsed : Visibility.Visible;
        _card.Margin = edge ? new Thickness(0) : new Thickness(_bare ? 12 : 13, 12, 12, 12);
        _card.CornerRadius = new CornerRadius(edge ? 0 : 16);
        _card.BorderThickness = new Thickness(edge ? 0 : 1);
    }

    User? SignedInUser => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User : null;

    void OnSessionChanged()
    {
        var user = SignedInUser;
        // 先取出登录弹窗携带的模板：关闭弹窗会触发 dismissed 清空它
        var template = user is not null ? _loginTemplate : null;
        if (user is not null) { _loginTemplate = null; _login?.Close(); }
        if (_accountId != user?.Id)
        {
            // 退出或换账号：与 Mac 一样清空对话、草稿，回到首页
            if (_accountId is not null) { ActiveChatId = null; _chat = null; _homeDraft = ""; PendingEditResume = null; PendingCreateKey = null; MockFocus = null; Selection = WorkspaceSection.Home; Bare = false; }
            _accountId = user?.Id;
            Announcements.Reset(user?.Id ?? "");
            _ = RefreshAccountDataAsync(user?.Id ?? "");
        }
        // 登录前选中的示例模板：回到模板页，按 key 匹配真实模板后打开创建弹窗
        if (template is not null) { PendingCreateKey = template.Key; Selection = WorkspaceSection.Templates; Bare = false; }
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

    /// <summary>窗口重新激活时刷新公告（Mac `didBecomeActiveNotification`）。</summary>
    public async void OnActivated()
    {
        await Announcements.RefreshAsync(App.Session.Api);
        Announcements.AutoOpenImportant(App.Session.Api);
        if (Announcements.Detail is not null) AnnouncementDetail.Show(this);
    }

    /// <summary>登录恢复失败等提示条（Mac 顶部黄色横条），恢复中时带“重试恢复”。</summary>
    void RenderBanner()
    {
        _banner.Children.Clear();
        if (App.Session.ErrorMessage is not { } message) return;
        var row = HStack(12, Label(message, 13, Txt));
        if (App.Session.Phase == SessionViewModel.SessionPhase.Restoring) row.Children.Add(new V3Button("重试恢复", () => _ = App.Session.RestoreAsync(), V3Button.Kind.Ghost, height: 28, small: true));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        _banner.Children.Add(new Border { Child = row, Padding = new Thickness(12), Background = Brush(Alpha(Hex(0xFFCC00), 0.1)) });
    }

    public void Select(WorkspaceSection section)
    {
        Selection = section;
        if (section != WorkspaceSection.Resumes) PendingEditResume = null;
        if (section != WorkspaceSection.Assistant) ActiveChatId = null;
        Bare = false;
        _sidebar.Render();
        ShowSection();
    }

    /// <summary>把一段文字放进首页对话输入框，等用户确认后发送（Mac `router.jump(.draft(text))`：截到 4000 字，切到首页）。</summary>
    public void Draft(string text)
    {
        var info = new System.Globalization.StringInfo(text);
        _homeDraft = info.LengthInTextElements <= 4000 ? text : info.SubstringByTextElements(0, 4000);
        Select(WorkspaceSection.Home);
    }

    /// <summary>兼容旧页面：`WorkspacePage.Current.Navigate(section)`。</summary>
    public void Navigate(WorkspaceSection section) => Select(section);

    public void OpenChat(string id)
    {
        _chat = (id, null, null, Guid.NewGuid());
        ActiveChatId = id;
        Selection = WorkspaceSection.Assistant;
        Bare = false;
        _sidebar.Render();
        ShowSection();
    }

    /// <summary>从首页发起新对话（Mac `startChat`）：带上第一条消息与首页选好的模型，清空首页草稿。</summary>
    public void StartChat(string text, string? model)
    {
        _chat = (null, text, model, Guid.NewGuid());
        _homeDraft = "";
        ActiveChatId = null;
        Selection = WorkspaceSection.Assistant;
        Bare = false;
        _sidebar.Render();
        ShowSection();
    }

    public void NewChat()
    {
        _homeDraft = "";
        _chat = null;
        Select(WorkspaceSection.Home);
    }

    public void ChatDeleted(string id)
    {
        if (ActiveChatId == id) { ActiveChatId = null; _chat = null; Select(WorkspaceSection.Home); }
    }

    /// <summary>打开简历编辑器（Mac `editResumeID = id; selection = .resumes`）。</summary>
    public void EditResume(string id)
    {
        PendingEditResume = id;
        Selection = WorkspaceSection.Resumes;
        ActiveChatId = null;
        Bare = true;
        _sidebar.Render();
        ShowSection();
    }

    /// <summary>编辑器关闭（Mac `editResumeID = nil; reload = UUID()`）：回到简历列表并重新读取。</summary>
    void CloseEditor()
    {
        PendingEditResume = null;
        Select(WorkspaceSection.Resumes);
    }

    /// <summary>首页“带着它去练”（Mac `mockFocus = focus; selection = .mock`）。</summary>
    public void Practice(object? focus)
    {
        MockFocus = focus;
        Select(WorkspaceSection.Mock);
    }

    /// <summary>首页“添加资料 / 选择文件”（Mac `importRequest = UUID(); selection = .resumes`）。</summary>
    public void RequestImport()
    {
        ImportRequest = Guid.NewGuid();
        Select(WorkspaceSection.Resumes);
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

    /// <summary>
    /// 登录后的首页（星图）。首页界面依赖 Core 的首页规则，由 <c>Views/Home</c> 在加载时注册；
    /// 未注册时（Core 首页规则尚未合并）退回引导首页。
    /// </summary>
    public static Func<string, Func<string>, Action<string>, UIElement>? SignedInHome { get; set; }

    void ShowSection()
    {
        var signedIn = SignedInUser is not null;
        // 昵称和头像更新会发布 User 变化；保留当前账号页及其编辑草稿。
        if (Selection == WorkspaceSection.Account && _content.Content is Views.Account.AccountPage) return;
        _content.Content = Selection switch
        {
            // 登录后与 Web 一致：首页是“哪里要提升”星图；游客仍显示引导首页
            WorkspaceSection.Home when signedIn && SignedInHome is { } home => home(SignedInUser!.Id, () => _homeDraft, text => _homeDraft = text),
            WorkspaceSection.Assistant when signedIn && _chat is { } chat => new Views.Assistant.AssistantChatView(chat.sessionId, chat.initial, chat.model),
            WorkspaceSection.Home => new AssistantHomePage(signedIn ? App.Session.User?.Nickname : null, _homeDraft, text => _homeDraft = text,
                () => Select(WorkspaceSection.Templates), () => RequestLoginAsync(reason: "登录 DrawOffer；你的输入会保留。"), ShowPluginAsync),
            WorkspaceSection.Account => new Views.Account.AccountPage(),
            WorkspaceSection.Datasets => new DatasetLibraryPage(),
            WorkspaceSection.Mock => new Views.Mock.MockInterviewView(this),
            WorkspaceSection.Schedule => new Views.Career.InterviewScheduleView(() => _ = RequestLoginAsync(reason: "登录后管理面试安排。")),
            WorkspaceSection.Jobs => new Views.Career.JobsBoardView(() => _ = RequestLoginAsync(reason: "登录后管理岗位和求职进度。")),
            // 与 Mac 一致：岗位广场只对已登录用户开放；从广场打开求职进程时切到投递看板并进入详情
            WorkspaceSection.Opportunities when signedIn => new Views.JobPool.JobPoolView(id => { Views.Career.JobsBoardView.OpenApplication = id; Select(WorkspaceSection.Jobs); }),
            WorkspaceSection.Templates => new TemplatesPage(),
            // 与 Mac `ResumesView.body` 一致：有待编辑的简历时直接进编辑器（铺满窗口、不显示侧栏），关闭后回到列表
            WorkspaceSection.Resumes when signedIn && PendingEditResume is { } edit => new Views.Resumes.ResumeEditorView(edit, CloseEditor),
            WorkspaceSection.Resumes => new Views.Resumes.ResumesView(SignedInUser?.Id ?? "", () => Select(WorkspaceSection.Templates), () => _ = RequestLoginAsync()),
            _ => Placeholder(Selection),
        };
    }

    /// <summary>尚未移植的栏目（Mac `PlaceholderView`）：标题、图标与“原生版本待实现”。</summary>
    static UIElement Placeholder(WorkspaceSection section) => VStack(10,
        new FontIcon { Glyph = section.Glyph(), FontSize = 28, FontFamily = IconFamily, Foreground = Brush(Fnt) },
        Serif(section.Title(), 20),
        Label("原生版本待实现", 13, Sub)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);

    async Task ShowPluginAsync()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "安装浏览器插件",
            Content = "浏览器插件在 Chrome / Edge 中使用，安装包与安装说明在 Web 的岗位看板页面提供。",
            PrimaryButtonText = "在浏览器打开", CloseButtonText = "知道了",
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) WebBridge.Open("/career/applications");
    }

    /// <summary>
    /// 需要登录时打开登录弹窗（Mac `LoginRequest` sheet：520×560、顶部原因与“暂不登录”）；已登录时与 Mac 一样提示“此功能尚未开放”。
    /// </summary>
    public async Task RequestLoginAsync(ResumeTemplate? template = null, string? reason = null)
    {
        if (_login is { IsOpen: true }) return;
        if (SignedInUser is not null)
        {
            var notice = new ContentDialog { XamlRoot = XamlRoot, Title = "此功能尚未开放", Content = "此功能将在后续版本开放。你已输入的内容会保留，可以继续浏览模板。", CloseButtonText = "知道了" };
            await notice.ShowAsync();
            return;
        }
        var text = reason ?? (template is null ? "登录后查看和同步你的简历。" : $"登录后继续使用「{template.Name}」。");
        var finished = new TaskCompletionSource();
        _loginTemplate = template;
        _login = V3Overlay.Show(XamlRoot, close =>
        {
            var head = Spread(Label(text, 15, Txt, Semibold), new V3Button("暂不登录", close, V3Button.Kind.Text));
            head.Margin = new Thickness(20);
            var body = new Grid();
            body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            body.RowDefinitions.Add(new RowDefinition { Height = Star() });
            body.Children.Add(head);
            var sign = new SignInView();
            SetRow(sign, 1);
            body.Children.Add(sign);
            var frame = V3Dialog.Frame(body, 520);
            frame.Height = 560;
            return frame;
        }, dismissed: () => { _loginTemplate = null; finished.TrySetResult(); });
        await finished.Task;
    }
}
