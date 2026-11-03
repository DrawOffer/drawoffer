using System.Text.Json.Nodes;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using G = DrawOffer.Core.Models.ResumeGuideModel;
using S = DrawOffer.App.Views.Resumes.GuideJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>请求与写入（Swift `ResumeGuidePanel` 的 MARK: Actions）。</summary>
public sealed partial class ResumeGuidePanel
{
    static IApiClient Api => App.Session.Api;

    static void ReportIfUnauthorized(Exception error)
    {
        if (S.IsUnauthorized(error)) App.Session.ReportAuthenticationFailure();
    }

    static bool Is409(Exception error) => S.IsServer(error, out var status, out _) && status == 409;

    static async Task<JsonNode?> TryGet(string path)
    {
        try { return await Api.CareerRequestAsync(path); } catch { return null; }
    }

    /// <summary>Swift `Task { try? await ... }`：吞掉错误，只保证界面不崩。</summary>
    static async Task Try(Func<Task> work)
    {
        try { await work(); } catch { }
    }

    /// <summary>Swift `.task`：打开时判断是否“欢迎回来”，读引导对话、画像、求职资料与模板示例。</summary>
    async Task StartAsync()
    {
        _welcome = _guide.Text("status") == "active" && Step != "materials";
        Render();
        await ReloadAsync();
        var user = TryGet("/api/account/user-profile");
        var careerProfile = TryGet("/api/account/career-profile");
        _profile = await user;
        _career = await careerProfile;
        _careerReady = true;
        Prefill();
        Render();
        if (_templateId is { } templateId && await TryGet($"/api/resume-templates/{templateId}") is { } template)
            _templateSample = template.Get("template").Get("data");
    }

    void SetGuide(JsonNode value)
    {
        _ref = value;
        _guide = value;
        _setGuide(value);
        StepMaybeChanged();
        Render();
    }

    /// <summary>Swift `.onChange(of: proposals) { prefill(); autoWrite() }`。</summary>
    void ProposalsChanged()
    {
        Prefill();
        AutoWrite();
    }

    void Next() => _ = Try(() => ChangeAsync("next"));
    void Skip() => _ = Try(() => ChangeAsync("skip_step"));

    async Task ChangeAsync(string action, string? target = null, IReadOnlyList<string>? datasets = null)
    {
        var body = new JsonObject { ["expected_version"] = S.Clone((_ref ?? _guide).Get("version")) ?? S.Num(1), ["action"] = action };
        if (target is not null) body["step"] = target;
        if (datasets is not null) body["dataset_ids"] = S.StringArray(datasets);
        try
        {
            if ((await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/guide", "PATCH", body: body)).Get("guide") is { } next) SetGuide(next);
        }
        catch (Exception error)
        {
            ReportIfUnauthorized(error);
            if (Is409(error) && (await TryGet($"/api/resumes/{_resumeId}/guide")).Get("guide") is { } latest) SetGuide(latest);
            throw;
        }
    }

    async Task ReloadAsync()
    {
        if (SessionId.Length == 0) return;
        var loaded = TryGet($"/api/agent/sessions/{SessionId}");
        var list = TryRequest(() => Api.CareerRequestAsync("/api/agent/proposals", "GET",
            new() { ["resume_id"] = _resumeId, ["session_id"] = SessionId, ["include_history"] = "true" }));
        if (await loaded is { } value && value.Get("session").Get("messages") is JsonArray messages) _messages = S.Arr(messages);
        if (await list is { } proposals && proposals.Get("proposals") is JsonArray items) { _proposals = S.Arr(items); ProposalsChanged(); }
        Render();
    }

    static async Task<JsonNode?> TryRequest(Func<Task<JsonNode>> request)
    {
        try { return await request(); } catch { return null; }
    }

    /// <summary>引导对话：资料一步交给 AI 读一遍；中途换了步骤（RESUME_GUIDE_STEP_MISMATCH）时重新读引导，不算失败。</summary>
    async Task SendAsync(string content, bool kickoff = false)
    {
        if (SessionId.Length == 0 || _running) return;
        _running = true;
        _streamText = "";
        _failure = null;
        Render();
        string? failed = null;
        var body = new JsonObject
        {
            ["content"] = content, ["idempotency_key"] = Guid.NewGuid().ToString().ToLowerInvariant(), ["guide_step"] = (_ref ?? _guide).Text("current_step"),
        };
        if (kickoff) body["guide_kickoff"] = true;
        try
        {
            if (Api is HttpApiClient client)
                await client.Coordinator.StreamAgentAsync($"/api/agent/sessions/{SessionId}/messages", "POST", body, frame =>
                {
                    if (AgentEvent.Parse(frame) is not { } agentEvent) return Task.FromResult(false);
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        switch (agentEvent.Type)
                        {
                            case "assistant.delta": _streamText += agentEvent.Data.Text("delta"); break;
                            case "proposal.created":
                                if (agentEvent.Data.Get("proposal") is { } proposal)
                                {
                                    _proposals = [S.Clone(proposal), .. _proposals.Where(p => p.Text("id") != proposal.Text("id"))];
                                    ProposalsChanged();
                                    Render();
                                }
                                break;
                            case "run.failed": failed = agentEvent.Data.Text("error").Length == 0 ? "failed" : agentEvent.Data.Text("error"); break;
                        }
                    });
                    return Task.FromResult(agentEvent.IsTerminal);
                });
        }
        catch (Exception error)
        {
            ReportIfUnauthorized(error);
            if (S.IsServer(error, out _, out var code) && code == "RESUME_GUIDE_STEP_MISMATCH")
            {
                if ((await TryGet($"/api/resumes/{_resumeId}/guide")).Get("guide") is { } latest) SetGuide(latest);
            }
            else failed = S.IsServer(error, out _, out var other) ? other : "failed";
        }
        // 让流里最后几帧先在界面线程上处理完
        await Task.Yield();
        await ReloadAsync();
        _streamText = "";
        _running = false;
        if (failed is not null)
            _failure = new Failure(failed is "CREDIT_INSUFFICIENT" or "PAID_CREDIT_REQUIRED" ? "credit" : "failed", () => _ = SendAsync(content, kickoff));
        Render();
    }

    /// <summary>写入：先保存编辑器，再执行服务端写入；记下写之前的正文供撤销。onError 返回 true 表示已自行处理（显示失败页）。</summary>
    async Task<bool> WriteAsync(string label, Func<Task> run, Func<string, bool>? onError = null)
    {
        var before = _data.DeepClone();
        var written = Step;
        _busy = true;
        _notice = null;
        Render();
        try
        {
            if (!await _saveFirst()) { _notice = "简历还没保存好，稍后再试。"; return false; }
            try
            {
                await run();
                _lastWrite = new LastWrite(written, before, label);
                return true;
            }
            catch (Exception error)
            {
                ReportIfUnauthorized(error);
                var code = S.IsServer(error, out _, out var server) ? server : "";
                if (onError?.Invoke(code) == true) return false;
                _notice = code is "TARGET_STALE" or "RESUME_EDIT_CONFLICT" ? "简历刚被改过，请再确认一次。"
                    : code == "RESUME_DRAFT_SAVE_FAILED" ? "简历还没保存好，稍后再试。" : "没写进去，简历没有改动，请重试。";
                return false;
            }
        }
        finally
        {
            _busy = false;
            Render();
        }
    }

    async Task WriteOperationsAsync(IEnumerable<JsonNode?> operations)
    {
        var result = await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/guide/writes", "POST",
            body: new JsonObject { ["step"] = (_ref ?? _guide).Text("current_step"), ["operations"] = S.Array(operations) });
        if (result.Get("guide") is { } next) SetGuide(next.DeepClone());
        if (result.Get("resume") is { } resume) _applied(resume.DeepClone());
    }

    async Task<JsonNode> ComposeAsync(string path, JsonObject body)
    {
        var result = await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/guide/{path}", "POST", body: body);
        if (result.Get("guide") is { } next) SetGuide(next.DeepClone());
        if (result.Get("resume") is { } resume) _applied(resume.DeepClone());
        return result;
    }

    async Task UndoLastAsync()
    {
        if (_lastWrite is not { } last) return;
        _undo(last.Before);
        _lastWrite = null;
        switch (last.Step)
        {
            case "skills": _skillLines = []; _skillPhase = "form"; break;
            case "experience": _bullets = []; if (_phase == "written") _phase = "form"; break;
            case "wrap_up": _profileText = ""; _wrapPhase = "main"; break;
        }
        Render();
        if (last.Step != Step) await Try(() => ChangeAsync("goto_step", last.Step));
    }

    void WriteSkills(string? instruction)
    {
        if (_skills is not { Count: > 0 } list) return;
        _skillPhase = "working";
        Render();
        _ = Try(async () =>
        {
            var body = new JsonObject
            {
                ["skills"] = S.Array(list.Select(s => (JsonNode?)new JsonObject { ["name"] = s.Name, ["level"] = s.Level })),
            };
            if (instruction is not null) { body["instruction"] = instruction; body["previous"] = S.Array(_skillLines); }
            var ok = await WriteAsync("专业技能", async () => _skillLines = S.Arr((await ComposeAsync("skills:compose", body)).Get("lines")),
                code => { _failure = new Failure(G.FailureKind(code), () => { _failure = null; WriteSkills(instruction); }); return true; });
            _skillPhase = ok ? "written" : "form";
            Render();
        });
    }

    void WriteExperience(G.ExperienceForm form, string? instruction)
    {
        var kind = form.Section;
        var entryId = form.EntryID ?? G.MatchingEntry(_data, form, Samples);
        var heading = G.EntryLines(G.EntryFormatOf([_data, _templateSample], [kind]), form.Name, form.Start, form.End, form.Role);
        _phase = "working";
        Render();
        _ = Try(async () =>
        {
            var body = new JsonObject
            {
                ["kind"] = kind, ["name"] = heading.Name, ["paragraphs"] = S.StringArray(heading.Paragraphs),
                ["role"] = form.Role, ["start"] = form.Start, ["end"] = form.End, ["did"] = form.Did,
                ["entry_id"] = entryId,
                ["title"] = entryId is null ? G.SectionTitle([_templateSample], kind) : null,
                ["result"] = S.Trimmed(form.Result).Length == 0 ? null : S.Trimmed(form.Result),
            };
            if (instruction is not null) { body["instruction"] = instruction; body["previous"] = S.StringArray(_bullets.Select(b => b.Text("text"))); }
            var ok = await WriteAsync("经历", async () =>
            {
                var result = await ComposeAsync("experience:compose", body);
                _experience = form with { EntryID = result.Get("entry_id").String() ?? entryId };
                _bullets = S.Arr(result.Get("bullets"));
            }, code => { _failure = new Failure(G.FailureKind(code), () => { _failure = null; WriteExperience(form, instruction); }); return true; });
            _phase = ok ? "written" : "form";
            Render();
        });
    }

    void WriteProfile(string? instruction)
    {
        _wrapPhase = "profile-working";
        Render();
        _ = Try(async () =>
        {
            var body = new JsonObject { ["title"] = G.SectionTitle([_templateSample], "profile") };
            if (instruction is not null) { body["instruction"] = instruction; body["previous"] = _profileText; }
            var ok = await WriteAsync("个人简介", async () => _profileText = (await ComposeAsync("profile:compose", body)).Text("text"),
                code => { _failure = new Failure(G.FailureKind(code), () => { _failure = null; WriteProfile(instruction); }); return true; });
            _wrapPhase = ok ? "profile" : "main";
            Render();
        });
    }

    /// <summary>技能、经历 AI 写好的草稿直接上纸（确认提案），写完进入“写好了，不满意说怎么改”。</summary>
    void AutoWrite()
    {
        if (Draft is not { } draft || _running || _busy || Step is not ("experience" or "skills") || _confirmed.Contains(draft.Text("id"))) return;
        _confirmed.Add(draft.Text("id"));
        var skillsStep = Step == "skills";
        _ = Try(async () =>
        {
            var ok = await WriteAsync(skillsStep ? "专业技能" : "经历要点", async () =>
            {
                var result = await Api.CareerRequestAsync($"/api/agent/proposals/{draft.Text("id")}/confirm", "POST", body: new JsonObject { ["entry"] = "editor" });
                if (result.Get("resume") is { } resume) _applied(resume.DeepClone());
            });
            if (!ok) return;
            if ((await TryGet($"/api/resumes/{_resumeId}/guide")).Get("guide") is { } latest) SetGuide(latest.DeepClone());
            await ReloadAsync();
            if (skillsStep) _skillPhase = "written"; else _phase = "written";
            Render();
        });
    }

    /// <summary>完成：联系方式只填求职资料的空位，资料里还没有经历时把这份简历读进去；画像只追加缺的事实；最后标记完成。</summary>
    async Task FinishAsync()
    {
        _busy = true;
        Render();
        try
        {
            if (_career is { } career)
            {
                var contacts = G.CareerContactChanges(_data, G.Personal(career));
                var readResume = !G.CareerHasExperience(career);
                if (contacts.Count > 0) await SaveCareerPersonalAsync(contacts, overwrite: false);
                if (readResume)
                {
                    var latest = await Api.CareerRequestAsync("/api/account/career-profile");
                    _career = await Api.CareerRequestAsync("/api/account/career-profile/read-resume", "POST",
                        body: new JsonObject { ["base_lock_version"] = S.Clone(latest.Get("lock_version")) ?? S.Num(0), ["resume_id"] = _resumeId });
                }
            }
            if (_profile is not null)
            {
                for (var attempt = 0; attempt < 2; attempt++)
                {
                    var latest = await Api.CareerRequestAsync("/api/account/user-profile");
                    if (G.ProfileWrite(_data, latest) is not { } update) break;
                    try { _profile = await Api.CareerRequestAsync("/api/account/user-profile", "PUT", body: update); break; }
                    catch (Exception error) when (Is409(error) && attempt == 0) { }
                }
            }
            await ChangeAsync("complete");
            _close();
        }
        catch (Exception error)
        {
            ReportIfUnauthorized(error);
            _notice = "没保存上，画像和简历都没有改动，请重试。";
        }
        finally
        {
            _busy = false;
            Render();
        }
    }

    /// <summary>画像整体保存、带版本号：先读最新画像，在其上合并；版本冲突时再读一次重试。</summary>
    async Task SaveProfileAsync(Func<JsonNode?, IReadOnlyDictionary<string, JsonNode?>> changes)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var latest = await Api.CareerRequestAsync("/api/account/user-profile");
            try
            {
                _profile = await Api.CareerRequestAsync("/api/account/user-profile", "PUT", body: G.ProfileUpdate(latest, changes(latest)));
                return;
            }
            catch (Exception error) when (Is409(error) && attempt == 0) { }
        }
    }

    /// <summary>求职资料的个人信息：`overwrite` 时用户亲手填的覆盖旧值，否则只填空位。</summary>
    async Task SaveCareerPersonalAsync(IReadOnlyDictionary<string, string> changes, bool overwrite)
    {
        if (changes.Count == 0) return;
        var latest = await Api.CareerRequestAsync("/api/account/career-profile");
        var personal = G.Personal(latest);
        foreach (var (key, value) in changes)
            if (overwrite || (personal.TryGetValue(key, out var old) ? old : "").Length == 0) personal[key] = value;
        var fields = new JsonObject();
        foreach (var (key, value) in personal) fields[key] = value;
        _career = await Api.CareerRequestAsync("/api/account/career-profile", "PUT",
            body: new JsonObject { ["base_lock_version"] = S.Clone(latest.Get("lock_version")) ?? S.Num(0), ["personal"] = fields });
    }
}
