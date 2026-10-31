using DrawOffer.App.DesignSystem;
using Microsoft.UI.Xaml;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>“我的额度”弹窗入口。完整的方案卡、积分明细与邀请好友在 W8（对应 Mac `PlansSheet.swift`）移植；在此之前先在浏览器打开 Web 的额度页。</summary>
public static class PlansDialog
{
    public static void Show(FrameworkElement owner) => V3Overlay.Show(owner.XamlRoot, close =>
        V3Dialog.Make(V3DialogHead.Make("我的额度", "额度与套餐的原生页面尚未完成，可以先在浏览器查看。"),
            [new V3Button("在浏览器打开", () => { close(); WebBridge.Open("/pricing/credits"); }, V3Button.Kind.Dark, height: 36)], close, width: 440));
}
