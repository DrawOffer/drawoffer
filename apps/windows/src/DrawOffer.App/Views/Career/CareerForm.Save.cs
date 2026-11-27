using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;

namespace DrawOffer.App.Views.Career;

/// <summary>`CareerForm.save()`：校验后按顺序创建岗位 → 阶段 → 排期 → 作答计划 → Offer，每步成功后记下结果，重试只做剩下的步骤。</summary>
public sealed partial class CareerForm
{
    string? Validate()
    {
        if (Creation && _current is null && (_company.Trim().Length == 0 || _role.Trim().Length == 0)) return "请填写公司和岗位名称。";
        if (NeedsStage && _stage == "interview" && _label.Trim().Length == 0) return "请填写面试名称。";
        if (NeedsStage && StageType == "oc" && !_ocAtSet) return "请填写沟通时间。";
        if (NeedsStage && ShowSchedule)
        {
            if (ScheduleRequired && !HasScheduleDetails) return "请选择开始时间或截止时间。";
            if (_stage == "assessment" && !_deadlineSet && !ScheduleRequired && HasScheduleDetails) return "截止时间必须晚于开放时间。";
            if (HasScheduleDetails)
            {
                if (IsWindow) { if (!_deadlineSet || _end <= SessionStart) return "截止时间必须晚于开放时间。"; }
                else if (!_slotSet) return _stage == "written_test" ? "请填写有效的笔试开始时间。" : $"请填写有效的{(IsHR ? "HR 面" : CareerStage.Label(_stage))}开始时间。";
            }
        }
        if (_stage == "offer" && _offerSalary.Length > 0 && (!double.TryParse(_offerSalary, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var salary) || salary < 0)) return "请填写有效薪资。";
        if (NeedsStage && IsWindow && _planSet && (_planStart < SessionStart || PlanFinish > _end)) return "作答计划必须完整落在官方作答时段内。";
        return null;
    }

    async Task SaveAsync()
    {
        if (_busy) return;
        _error = null;
        if (Validate() is { } invalid) { _error = invalid; Render(); return; }
        _busy = true; Render();
        var creating = false;
        try
        {
            if (_kind is "arranged" or "schedule" && _selectedExisting.Length > 0 && _current is null)
            {
                var detail = await RequestAsync($"/api/job-applications/{_selectedExisting}");
                _current = new CareerApplication(detail["application"] ?? new JsonObject());
            }
            if (Creation && _current is null)
            {
                if (_createdApplicationId is null)
                {
                    creating = true;
                    var result = await RequestAsync("/api/job-descriptions", "POST", new JsonObject
                    {
                        ["company_name"] = _company.Trim(), ["job_title"] = _role.Trim(), ["description"] = _description, ["source_type"] = "manual",
                        ["employment_type"] = _category.Length == 0 ? null : _category, ["work_city"] = _city.Length == 0 ? null : _city,
                    });
                    if (result["application"].Display("id") is not { Length: > 0 } id) { _creationUnknown = true; throw new InvalidDataException(); }
                    _createdApplicationId = id; creating = false;
                }
                var created = await RequestAsync($"/api/job-applications/{_createdApplicationId}");
                _current = new CareerApplication(created["application"] ?? new JsonObject());
            }
            if (_current is not { } current) throw new InvalidDataException();
            if (_kind == "offer")
            {
                var target = current;
                if (current.Raw.Get("current_stage").Text("stage_type") == "oc" && !_staged)
                {
                    _frozenStage ??= new JsonObject { ["client_request_id"] = Guid.NewGuid().ToString("D").ToUpperInvariant(), ["base_lock_version"] = current.LockVersion, ["stage_type"] = "offer" };
                    var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{current.Id}/stages", "POST", null, _frozenStage.DeepClone());
                    target = new CareerApplication(result["application"] ?? new JsonObject()); _current = target; _staged = true;
                }
                await SaveOfferAsync(target);
            }
            else if (_kind is "accept" or "decline")
                await RequestAsync($"/api/job-applications/{current.Id}/close", "POST", new JsonObject { ["base_lock_version"] = current.LockVersion, ["status"] = "closed", ["offer_status"] = _kind == "accept" ? "accepted" : "declined" });
            else if (_kind is "archive" or "restore")
                await RequestAsync($"/api/job-applications/{current.Id}/{_kind}", "POST", new JsonObject { ["base_lock_version"] = current.LockVersion });
            else if (_kind == "notes")
                await RequestAsync($"/api/job-applications/{current.Id}", "PUT", new JsonObject { ["base_lock_version"] = current.LockVersion, ["notes"] = _notes });
            else if (_kind == "category")
                await RequestAsync($"/api/job-applications/{current.Id}", "PUT", new JsonObject { ["base_lock_version"] = current.LockVersion, ["employment_type"] = _category.Length == 0 ? null : _category });
            else if (_kind == "delete") await RequestAsync($"/api/job-applications/{current.Id}", "DELETE");
            else if (_kind == "terminate")
            {
                _frozenStage ??= new JsonObject { ["client_request_id"] = Guid.NewGuid().ToString("D").ToUpperInvariant(), ["base_lock_version"] = current.LockVersion, ["reason"] = _reason };
                await App.Session.Api.CareerRequestAsync($"/api/job-applications/{current.Id}/terminate", "POST", null, _frozenStage.DeepClone());
            }
            else if (NeedsStage) await SaveStageAsync(current);
            _busy = false;
            _completed();
            return;
        }
        catch (Exception error)
        {
            if (error is ApiException api && (int)api.Status is 400 or 422 or 409 && api.Code != "INTERVIEW_EDIT_CONFLICT")
            {
                if (!_staged) _frozenStage = null;
                if (!_savedSession) _frozenSession = null;
                _frozenOffer = null;
            }
            if (creating) _creationUnknown = !(error is ApiException { } failed && (int)failed.Status is >= 400 and < 500);
            _error = _creationUnknown ? "创建结果尚未确认。请关闭后刷新岗位列表确认，避免重复创建。" : Explain(error);
        }
        _busy = false;
        Render();
    }

    async Task SaveStageAsync(CareerApplication current)
    {
        if (_reuseCurrentStage && !_staged) { _savedStage = current.Raw; _staged = true; }
        if (!_staged)
        {
            if (_frozenStage is null)
            {
                var pending = current.Stage == "pending";
                var fields = new JsonObject
                {
                    ["client_request_id"] = Guid.NewGuid().ToString("D").ToUpperInvariant(), ["base_lock_version"] = current.LockVersion, ["stage_type"] = StageType,
                    ["applied_at"] = pending ? Iso(_appliedAt) : null, ["resume_id"] = _selectedResume.Length == 0 ? null : _selectedResume,
                };
                if (StageType == "interview") { fields["stage_label"] = _label; fields["interview_round_no"] = _round; }
                if (pending && _channel.Trim().Length > 0) fields["applied_channel"] = _channel.Trim();
                if (StageType == "oc")
                {
                    static JsonNode? Optional(string value) => value.Trim().Length == 0 ? null : value.Trim();
                    fields["oc_communicated_at"] = Iso(_ocAt);
                    fields["oc_start_text"] = Optional(_ocStartText);
                    fields["oc_note"] = Optional(_ocNote);
                    fields["oc_salary_text"] = Optional(_oralSalary);
                    fields["oc_contact"] = Optional(_ocContact);
                }
                _frozenStage = fields;
            }
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{current.Id}/stages", "POST", null, _frozenStage.DeepClone());
            _savedStage = result["application"]; _current = new CareerApplication(_savedStage ?? new JsonObject()); _staged = true;
        }
        if (HasScheduleDetails && ShowSchedule && !_savedSession)
        {
            if (_frozenSession is null)
            {
                var begin = SessionStart;
                var finish = IsWindow ? _end : begin.AddMinutes(_duration);
                var mode = _stage == "interview" || (_stage == "written_test" && !IsWindow) ? _interviewMode : "video";
                var place = _meeting.Trim();
                var note = _prepNote.Trim();
                var person = _interviewer.Trim();
                var fields = new JsonObject
                {
                    ["client_request_id"] = Guid.NewGuid().ToString("D").ToUpperInvariant(), ["application_stage_id"] = _savedStage.Get("current_stage").Get("id")?.DeepClone(),
                    ["stage_type"] = IsHR ? "hr" : _stage == "interview" ? "interview" : "other",
                    ["stage_label"] = _reuseCurrentStage ? (current.Raw.Get("current_stage").Text("stage_label").NonEmpty() ?? _label) : _stage == "interview" ? _label : CareerStage.Label(_stage),
                    ["round_no"] = _stage == "interview" && !IsHR ? _round : null,
                    ["start_at"] = Iso(begin), ["end_at"] = Iso(finish),
                    ["schedule_kind"] = IsWindow ? "open_window" : "fixed_slot", ["timezone"] = JobsBoardView.TimeZoneId(), ["mode"] = mode,
                    ["meeting_url"] = mode is "video" or "phone" && place.Length > 0 ? place : null,
                    ["location"] = mode is "onsite" or "other" && place.Length > 0 ? place : null,
                    ["preparation_note"] = note.Length == 0 ? null : note,
                };
                if (_stage == "interview" && person.Length > 0) fields["interviewer_name"] = person;
                _frozenSession = fields;
            }
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{current.Id}/interview-sessions", "POST", null, _frozenSession.DeepClone());
            _createdSession = result["session"];
            _savedSession = true;
        }
        if (_savedSession && IsWindow && _planSet && !_savedPlan)
        {
            if (_createdSession is not { } created || created.Text("id").Length == 0) throw new InvalidDataException();
            _frozenPlan ??= new JsonObject { ["base_lock_version"] = created["lock_version"]?.DeepClone() ?? 1, ["answer_plan_start_at"] = Iso(_planStart), ["answer_plan_end_at"] = Iso(PlanFinish) };
            try
            {
                var result = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{created.Text("id")}/answer-plan", "PUT", null, _frozenPlan.DeepClone());
                _createdSession = result["session"] ?? created; _savedPlan = true;
            }
            catch (Exception)
            {
                // 丢失的响应不能让已成功的计划看起来未保存，也不能覆盖更新的计划
                JsonNode? remote = null;
                try { remote = (await RequestAsync($"/api/interview-sessions/{created.Text("id")}"))["session"]; } catch (Exception) { }
                var desiredStart = CareerApplication.Date(_frozenPlan.Text("answer_plan_start_at"));
                var desiredEnd = CareerApplication.Date(_frozenPlan.Text("answer_plan_end_at"));
                if (remote is not null && desiredStart is not null && desiredEnd is not null
                    && CareerApplication.Date(remote.Text("answer_plan_start_at")) == desiredStart && CareerApplication.Date(remote.Text("answer_plan_end_at")) == desiredEnd)
                { _createdSession = remote; _savedPlan = true; }
                else throw;
            }
        }
        if (_stage == "offer" && _offerIntent == "received") await SaveOfferAsync(_current!);
    }
}
