import DrawOfferCore
import SwiftUI

/// 对话中积分不足（macOS 稿 01 页「05 · 会员与积分的入口」05.01）：回复位置上的一张白卡，
/// 标题 14/600「积分不足，未能生成回复」→ 13 sub 说明 → 「开通会员」墨黑 / 「购买积分」白底 / 可选的改用便宜模型重发（下划线文字链）。
/// 由对话页接入：`onPlans` 打开会员与积分弹窗的会员方案（`PlansSheet(initialTab: "membership")`），
/// `onCredits` 打开积分充值（`PlansSheet(initialTab: "pack")`），`fallback` 为空时不显示第三个入口。
struct AccountCreditsShortCard: View {
    var title = "积分不足，未能生成回复"
    /// 例如「当前剩余 2 积分，GPT 6 Sol 平均每次对话约 18 积分。补充积分后可直接重新发送，你的消息已保留。」
    let message: String
    let onPlans: () -> Void
    let onCredits: () -> Void
    /// 例如（"改用 GPT 6 Luna 重新发送（约 1 积分）", 动作）。
    var fallback: (label: String, action: () -> Void)? = nil
    /// 「把消息放回输入框」（Web 没有这一项，客户端保留原有入口）。
    var restore: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(height: 20)
            Text(message).font(V3.sans(13)).foregroundStyle(V3.sub).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            HStack(spacing: 10) {
                // 05.01：开通会员是系统 Prominent 按钮（墨黑、圆角 7），购买积分是白底 #E4E4E0 描边 38 高
                Button("开通会员", action: onPlans).buttonStyle(.borderedProminent).tint(V3.txt).controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: 7)).font(V3.sans(13, weight: .medium))
                Button("购买积分", action: onCredits).buttonStyle(CreditsShortOutlineStyle())
                if let fallback {
                    Button(action: fallback.action) { Text(fallback.label).underline() }
                        .buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub).padding(.leading, 2)
                }
                if let restore {
                    Button("把消息放回输入框", action: restore).buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(V3.link)
                }
            }.padding(.top, 17)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 11.5))
        .overlay(RoundedRectangle(cornerRadius: 11.5).stroke(V3.cl))
        .accessibilityElement(children: .contain)
    }
}

/// 05.01 的「购买积分」：白底、#E4E4E0 描边、圆角 6.5、38 高。
private struct CreditsShortOutlineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 16).frame(height: 38)
            .background(configuration.isPressed ? V3.field : Color.white, in: RoundedRectangle(cornerRadius: 6.5))
            .overlay(RoundedRectangle(cornerRadius: 6.5).stroke(V3.cl)).contentShape(RoundedRectangle(cornerRadius: 6.5))
    }
}
