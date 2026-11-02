using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>Mac MockInterviewView 的 V2 路由；进入场次隐藏侧栏，报告和首页恢复工作区。</summary>
public sealed class MockInterviewView : UserControl
{
    readonly WorkspaceShell _shell;
    PracticeFocus? _focus;
    public MockInterviewView(WorkspaceShell shell)
    {
        _shell = shell; _focus = shell.MockFocus as PracticeFocus; shell.MockFocus = null;
        Unloaded += (_, _) => shell.Bare = false;
        if (App.Session.User is null)
            Content = VStack(14, Serif("模拟面试", 32), Sans("按简历与目标岗位练习，回看每个知识点答到了哪一层。", 14, Sub).Wrap(), new V3Button("登录后开始练习", () => _ = shell.RequestLoginAsync(reason: "登录后开始模拟面试。"), V3Button.Kind.Dark)).Align(Microsoft.UI.Xaml.HorizontalAlignment.Center, Microsoft.UI.Xaml.VerticalAlignment.Center);
        else Home();
    }
    void Home()
    {
        _shell.Bare = false;
        Content = new MockHomeView(_focus, Open, Report, Records,
            () => _shell.Select(WorkspaceSection.Resumes), () => _shell.Select(WorkspaceSection.Jobs),
            () => _shell.Select(WorkspaceSection.Datasets), () => _shell.Select(WorkspaceSection.Schedule));
        _focus = null;
    }
    void Records() { _shell.Bare = false; Content = new MockRecordsView(Home, Open); }
    void Open(string id) { if (string.IsNullOrEmpty(id)) return; _shell.Bare = true; Content = new MockSessionView(id, Home, Report, Open); }
    void Report(string id) { if (string.IsNullOrEmpty(id)) return; _shell.Bare = false; Content = new MockReportView(id, Home, Records, focus => { _focus = focus; Home(); }, Open); }
}
