using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Xunit;

namespace DrawOffer.Core.Tests;

// 与 apps/mac/Tests/DrawOfferCoreTests 同一组断言，保证两端核心层行为一致
public class CoreTests
{
    [Fact]
    public async Task MockTemplatesRequireSignIn()
    {
        var error = await Assert.ThrowsAsync<ApiException>(() => new MockApiClient().ListResumeTemplatesAsync());
        Assert.Equal("UNAUTHORIZED", error.Code);
    }

    [Fact]
    public async Task MockTemplatesAreEmptyAfterSignIn()
    {
        // 客户端不携带模板，真实目录只来自后端
        Assert.Empty(await new MockApiClient(signedIn: true).ListResumeTemplatesAsync());
    }

    // 只是接口结构样例，不是可见模板
    private const string TemplateShape = """
        {"id":"7","key":"shape-sample-cn","name":"结构样例","description":null,"style_categories":[],"use_cases":[],
         "data":{"schema_version":"canonical-resume.v1","sections":[]},
         "style":{"schema_version":"template-definition.v1","template_key":"shape-sample-cn"},
         "layout_plan":{"schema_version":"layout-plan.v1"},"use_count":3}
        """;

    [Fact]
    public void RenderRequestMatchesWebPresentationRule()
    {
        var template = System.Text.Json.JsonSerializer.Deserialize<ResumeTemplate>(TemplateShape)!;
        Assert.Equal(3, template.UseCount);
        Assert.NotNull(template.LayoutPlan);
        var request = JsonNode.Parse(template.ToRenderRequest().ToJson())!;
        Assert.Equal(1, request["protocol_version"]!.GetValue<int>());
        Assert.Equal("resume-presentation.v1", request["style"]!["schema_version"]!.GetValue<string>());
        Assert.NotNull(request["style"]!["template_scoped"]![template.Key]);
        Assert.True(JsonNode.DeepEquals(template.Style, request["style"]!["template_snapshot"]));
    }

    [Fact]
    public async Task SessionRestoreAndSignOut()
    {
        var session = new SessionViewModel(new MockApiClient(signedIn: true));
        await session.RestoreAsync();
        Assert.Equal(SessionViewModel.SessionPhase.SignedIn, session.Phase);
        await session.SignOutCommand.ExecuteAsync(null);
        Assert.Equal(SessionViewModel.SessionPhase.SignedOut, session.Phase);
    }

    private sealed class DelayedIdentityApi : IApiClient
    {
        public TaskCompletionSource<User?> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<User?> CurrentUserAsync(CancellationToken ct = default) => Result.Task;
        public Task<User> SignInAsync(string email, string password, CancellationToken ct = default) => Task.FromResult(MockApiClient.PreviewUser);
        public Task SignOutAsync(CancellationToken ct = default) => Task.CompletedTask;
        public Task<IReadOnlyList<ResumeTemplate>> ListResumeTemplatesAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<ResumeTemplate>>([]);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SessionIgnoresRestoreAfterSignOut(bool failure)
    {
        var api = new DelayedIdentityApi();
        var session = new SessionViewModel(api);
        var restore = session.RestoreAsync();
        await session.SignOutCommand.ExecuteAsync(null);
        if (failure) api.Result.SetException(new ApiException(System.Net.HttpStatusCode.Unauthorized, "SESSION_INVALID"));
        else api.Result.SetResult(MockApiClient.PreviewUser);
        await restore;
        Assert.Equal(SessionViewModel.SessionPhase.SignedOut, session.Phase);
        Assert.Null(session.User);
        Assert.Null(session.ErrorMessage);
    }

    [Fact]
    public void NavigationMatchesWebOrder()
    {
        var titles = WorkspaceSections.Sidebar.Select(section => section.Title());
        Assert.Equal(["首页", "我的简历", "简历模板", "投递看板", "面试日程", "模拟面试", "岗位广场", "资料库"], titles);
    }
}
