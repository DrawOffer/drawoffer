using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml.Controls;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 模拟面试模块入口（Windows 稿 09 · 模拟面试；Mac `MockInterviewView`）：首页 → 面试设置 → 面试中（全屏，无侧栏）→ 复盘；全部记录、导入面试记录从首页进。
/// 首页星图“去练”带来的练习焦点直接打开面试设置；首页点开的某一场直接进这一场（进行中接着答，完成的看复盘）。
/// </summary>
public sealed class MockInterviewView : UserControl
{
    readonly WorkspaceShell _shell;

    public MockInterviewView(WorkspaceShell shell)
    {
        _shell = shell;
        Unloaded += (_, _) => shell.Bare = false;
        var focus = shell.MockFocus as PracticeFocus;
        var session = shell.MockSession;
        shell.MockFocus = null; shell.MockSession = null;
        if (session is { Length: > 0 }) Open(session);
        else if (focus is not null) Config(focus);
        else Home();
    }

    void Show(UserControl page, bool bare = false)
    {
        _shell.Bare = bare;
        Content = page;
    }

    void Home() => Show(new MockHomeView(Open, Records, () => _shell.Select(WorkspaceSection.Resumes), () => Config()));

    /// <summary>面试设置（Windows 稿 09 · 02）。</summary>
    void Config(PracticeFocus? focus = null, MockPracticePlan? plan = null) =>
        Show(new MockConfigPage(focus, plan, Home, Open, () => _shell.Select(WorkspaceSection.Jobs), () => _shell.Select(WorkspaceSection.Opportunities)));

    void Records() => Show(new MockRecordsView(Home, Report, Open,
        (_, application) => { if (application is not null) _shell.OpenApplication(application); else _shell.Select(WorkspaceSection.Jobs); },
        () => Config()));

    /// <summary>面试中（准备、作答、结束）是无侧栏的全屏画面；完成的场次交给复盘。</summary>
    void Open(string id)
    {
        if (string.IsNullOrEmpty(id)) return;
        Show(new MockSessionView(id, Home, Report, Open), bare: true);
    }

    /// <summary>面试复盘（Windows 稿 09 · 10）：带侧栏。</summary>
    void Report(string id)
    {
        if (string.IsNullOrEmpty(id)) return;
        Show(new MockReportView(id, Home, Records, focus => Config(focus), Open, plan => Config(plan: plan)));
    }
}
