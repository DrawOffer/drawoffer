import DrawOfferCore
import SwiftUI

/// 深层页面（求职详情、复盘报告等）跳转到工作区其他栏目的入口，由 `WorkspaceView` 注入并消费。
/// `draft` 只把文字放进首页输入框，由用户确认后再发送，不替用户自动发起对话。
@MainActor @Observable
final class WorkspaceRouter {
    /// `materials`：投递详情里的资料页，`session` 为 nil 时是全部场次（Web `careerMaterialsPath`）；
    /// `mock`：进模拟面试，带着练习重点（nil 为普通新建）；`mockSession`：直接打开某一场；`dataset`：打开资料预览页；`careerProfile`：账号下的求职画像页；`feedback`：整窗反馈页；`credits`：额度弹窗的积分页。
    enum Jump: Equatable { case section(WorkspaceSection), draft(String), editResume(String), plans, application(String), materials(application: String, session: String?), mock(PracticeFocus?), mockSession(String), mockPractice(MockPracticePlan), job(JobTarget), mockFor(application: String), dataset(String), careerProfile, feedback, credits }
    /// 按 id 打开一个岗位详情（Web `jobDetailPath(id, applicationId?)`）；带投递 id 时详情里显示该投递的阶段与简历。
    struct JobTarget: Equatable { let id: String; var applicationID: String? = nil }
    private(set) var pending: Jump?

    func jump(_ target: Jump) { pending = target }
    func take() -> Jump? { defer { pending = nil }; return pending }
}
