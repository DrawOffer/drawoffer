using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;

namespace DrawOffer.Core.Session;

/// <summary>登录态，对应 Mac 端的 SessionStore。工作区始终开放，Phase 控制账号操作与登录弹窗。</summary>
public sealed partial class SessionViewModel(IApiClient api) : ObservableObject
{
    public enum SessionPhase { Restoring, SignedOut, SignedIn }

    public IApiClient Api { get; } = api;
    private long _operation;

    [ObservableProperty] private SessionPhase _phase = SessionPhase.Restoring;
    [ObservableProperty] private User? _user;
    [ObservableProperty] private string? _errorMessage;

    public async Task RestoreAsync()
    {
        var current = ++_operation;
        ErrorMessage = null;
        try
        {
            var user = await Api.CurrentUserAsync();
            if (current != _operation) return;
            Apply(user);
        }
        catch (ApiException error) when (error.Status == System.Net.HttpStatusCode.Unauthorized)
        {
            if (current != _operation) return;
            Apply(null);
            ErrorMessage = "登录已失效，请重新登录。";
        }
        catch (Exception)
        {
            if (current != _operation) return;
            User = null;
            Phase = SessionPhase.Restoring;
            ErrorMessage = "暂时无法恢复登录，可重试；已保留安全凭据。";
        }
    }

    [RelayCommand]
    private async Task SignInAsync((string Email, string Password) credentials)
    {
        var current = ++_operation;
        ErrorMessage = null;
        try
        {
            var user = await Api.SignInAsync(credentials.Email, credentials.Password);
            if (current != _operation) return;
            Apply(user);
        }
        catch (ApiException)
        {
            if (current != _operation) return;
            ErrorMessage = "登录失败，请检查邮箱和密码。";
        }
    }

    [RelayCommand]
    private async Task SignOutAsync()
    {
        var current = ++_operation;
        Apply(null);
        ErrorMessage = null;
        try { await Api.SignOutAsync(); }
        catch (Exception)
        {
            if (current != _operation) return;
            ErrorMessage = "本地已退出；远端撤销或安全存储清理未确认，请重试。";
        }
    }

    private void Apply(User? user)
    {
        User = user;
        Phase = user is null ? SessionPhase.SignedOut : SessionPhase.SignedIn;
    }

    public async Task CompleteDesktopLoginAsync(DesktopLoginChallenge challenge, CancellationToken ct = default)
    {
        if (Api is not HttpApiClient client) throw new InvalidOperationException("Desktop HTTP client required");
        var current = _operation;
        var user = await client.Coordinator.CompleteLoginAsync(challenge, ct);
        if (current != _operation) throw new OperationCanceledException();
        ErrorMessage = null;
        Apply(user);
    }

    public void ReportAuthenticationFailure()
    {
        ++_operation;
        Apply(null);
        ErrorMessage = "登录已失效，请重新登录。";
    }

    /// <summary>头像换了以后只更新本地用户，不必重新拉取（Mac `updateAvatar`）。</summary>
    public void UpdateAvatar(string? path)
    {
        if (Phase == SessionPhase.SignedIn && User is { } user) User = user with { AvatarUrl = path };
    }

    /// <summary>浏览器登录：打开授权页后等待 `drawoffer://` 回调；`BrowserLoginPending` 用于界面显示等待状态（Mac `SessionStore`）。</summary>
    [ObservableProperty] private bool _browserLoginPending;

    public async Task CompleteBrowserLoginAsync(Uri callback)
    {
        // 没有进行中的浏览器登录时忽略回调（例如重复点击了旧页面的“打开 DrawOffer”）。
        if (!BrowserLoginPending || Api is not HttpApiClient client) return;
        var current = _operation;
        try
        {
            var user = await client.Coordinator.CompleteBrowserLoginAsync(callback);
            if (current != _operation) return;
            ErrorMessage = null;
            BrowserLoginPending = false;
            Apply(user);
        }
        catch (Exception error)
        {
            if (current != _operation) return;
            BrowserLoginPending = false;
            ErrorMessage = error switch
            {
                ApiException { Status: System.Net.HttpStatusCode.Gone } => "授权已过期，请重新登录。",
                ApiException { Status: System.Net.HttpStatusCode.BadRequest, Code: "LOGIN_CALLBACK_INVALID" } or ApiException { Status: System.Net.HttpStatusCode.Unauthorized }
                    => "登录回调与本次请求不匹配，请从客户端重新点击登录。",
                _ => "登录未完成，请检查网络后重新登录。",
            };
        }
    }
}
