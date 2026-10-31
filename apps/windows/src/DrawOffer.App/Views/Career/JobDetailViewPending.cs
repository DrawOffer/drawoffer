using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 临时：Mac `JobDetailView.swift`（岗位详情）随 W5 岗位广场移植，届时删除本文件。
/// 现在只显示返回与“在浏览器打开”，签名与 Mac 一致，求职进度页的“岗位信息”入口不至于点了没反应。
/// </summary>
public sealed class JobDetailView : UserControl
{
    public JobDetailView(string jobId, JsonNode? application, Action back, Action deleted)
    {
        Content = VStack(14,
            CareerBreadcrumb.Make("返回求职进度", "岗位详情", back),
            Serif("岗位详情", 20).Top(12),
            Sans("岗位详情的原生页面还在移植中，可以先在浏览器里查看和编辑。", 13, Sub).Wrap(),
            new V3Button("在浏览器打开", () => WebBridge.Open("/career/applications"), V3Button.Kind.Ghost).Top(4))
            .Pad(40, 40, 40, 40);
    }
}
