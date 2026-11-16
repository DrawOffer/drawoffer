using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Account;

/// <summary>
/// 求职画像（Windows 稿 01 页「03 · 求职画像」03.02–03.08，逻辑对齐 Mac `CareerProfileView` / Web `CareerProfilePage`）：
/// 账号唯一的一份，网申插件和 AI 都只用它。720 宽一列两栏输入框，离开输入框自动保存；
/// 教育、实习、工作、项目各一个分区，标题右侧蓝字「＋ 添加」原地展开一段表单；技能是可切换熟练度的胶囊。
/// </summary>
public sealed class CareerProfileView : UserControl
{
    static readonly Color Asked = Hex(0xC9711C);
    readonly Action _back;
    readonly StackPanel _column = new() { HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(0, 24, 0, 72) };
    readonly TextBlock _missing = Sans("", 12, Asked, Medium), _missingLead = Sans("", 12, Fnt), _status = Sans("", 12, Faint);
    JsonNode? _profile, _intent;
    bool _failed, _disposed;
    int _saving;
    Task _queue = Task.CompletedTask;
    /// <summary>刚点「添加」还没填的段只在页面上，第一次填写才保存，免得留下空段被插件填进表单。</summary>
    readonly List<(string Id, string Group)> _drafts = [];

    public CareerProfileView(Action back)
    {
        _back = back;
        Background = Brush(White);
        Content = Scroll(_column);
        SizeChanged += (_, e) => _column.Width = Math.Min(720, Math.Max(480, e.NewSize.Width - 64));
        Loaded += async (_, _) => { Render(); await LoadAsync(); };
        Unloaded += (_, _) => _disposed = true;
    }

    JsonNode Experience => _profile?["experience"] is JsonObject value ? value : ProfileModel.EmptyExperience();

    async Task LoadAsync()
    {
        try
        {
            var career = AccountPage.Request("/api/account/career-profile");
            var portrait = AccountPage.Request("/api/account/user-profile");
            await Task.WhenAll(career, portrait);
            _profile = career.Result; _intent = portrait.Result; _failed = false;
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _failed = true;
        }
        if (!_disposed) Render();
    }

    // MARK: 渲染

    void Render()
    {
        _column.Children.Clear();
        _column.Children.Add(HStack(5, Icon("chevron.left", 10, Fnt), Sans("账号设置", 13, Fnt)).OnTap(_back, "返回账号设置"));
        if (_failed && _profile is null)
        {
            _column.Children.Add(VStack(12, Label("暂时无法读取求职画像", 18, Txt, Semibold),
                new V3Button("重新加载", () => { _failed = false; Render(); _ = LoadAsync(); })).Top(40));
            return;
        }
        if (_profile is not { } profile || _intent is not { } intent) { _column.Children.Add(new V3Loading("正在加载求职画像…").Top(160)); return; }

        // 03.02 页头：24/600 标题 + 13 sub 说明；右侧「网申常问的还差 N 项 · 已保存」
        var status = HStack(0, _missingLead, _missing, _status);
        status.VerticalAlignment = VerticalAlignment.Bottom;
        UpdateStatus();
        _column.Children.Add(new Border
        {
            BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 14, 0, 24),
            Child = Spread(VStack(4, Label("求职画像", 24, Txt, Semibold), Sans("网申插件和 AI 都用这一份。直接填写，离开输入框就自动保存。", 13, Sub)), status, 24, VerticalAlignment.Bottom),
        });

        _column.Children.Add(Section("基本信息", null, null, TwoColumns(ProfileModel.Basic.Select(row => Cell(PersonalField(row, profile))))));
        var idTypes = profile["catalog"]?["id_types"].Items().Select(x => x.GetValue<string>()).ToArray() ?? [];
        var identity = new List<(UIElement, bool)>
        {
            Cell(Field("证件类型", Select("证件类型", profile.Text("id_type"), idTypes, next => Save(_ => new() { ["id_type"] = next }, true)))),
            Cell(IdNumber(profile)),
        };
        identity.AddRange(ProfileModel.Identity.Select(row => Cell(PersonalField(row, profile))));
        _column.Children.Add(Section("身份与证件", "网申常问，填一次所有公司通用。证件号加密保存，页面只显示首尾几位。", null, TwoColumns(identity)));
        _column.Children.Add(Section("求职意向", "AI 出题和网申都会用。", null, IntentFields(intent)));
        Experiences();
        _column.Children.Add(Section("技能", "写简历、模拟面试都按熟练度来，点一下切换熟练度。", null, Skills(), last: true));
    }

    void UpdateStatus()
    {
        if (_profile is null) return;
        var missing = CareerProfileRules.Missing(_profile).Length;
        _missingLead.Text = missing == 0 ? "网申常问的信息都填好了" : "网申常问的还差 ";
        _missing.Text = missing == 0 ? "" : $"{missing} 项";
        _status.Text = _saving > 0 ? " · 保存中…" : " · 已保存";
    }

    /// <summary>分区：标题 16/600，说明 12 fnt（距 6）；右侧可放蓝字「＋ 添加」；上 32、下 32，下边线。</summary>
    static Border Section(string title, string? desc, (string Label, Action Action)? add, UIElement content, bool last = false)
    {
        var titles = VStack(6, Label(title, 16, Txt, Semibold), desc is null ? null : Sans(desc, 12, Fnt).Wrap());
        UIElement head = titles;
        if (add is { } action)
            head = Spread(titles, HStack(4, Icon("plus", 10, Blue), Sans("添加", 13, Blue)).OnTap(action.Action, action.Label), 16);
        return new Border
        {
            Padding = new Thickness(0, 32, 0, 32), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, last ? 0 : 1),
            Child = VStack(0, head, content is FrameworkElement element ? element.Top(20) : content),
        };
    }

    static (UIElement, bool) Cell(UIElement element, bool wide = false) => (element, wide);

    /// <summary>两栏网格：列宽相等、列距 40、行距 16；wide 的格子独占一行。</summary>
    static StackPanel TwoColumns(IEnumerable<(UIElement Element, bool Wide)> cells)
    {
        var stack = new StackPanel { Spacing = 16 };
        List<UIElement> pending = [];
        void Flush()
        {
            if (pending.Count == 0) return;
            stack.Children.Add(Columns(40, (Star(), pending[0]), (Star(), pending.Count > 1 ? pending[1] : new Border())));
            pending.Clear();
        }
        foreach (var (element, wide) in cells)
        {
            if (wide) { Flush(); stack.Children.Add(element); continue; }
            pending.Add(element);
            if (pending.Count == 2) Flush();
        }
        Flush();
        return stack;
    }

    /// <summary>标签在上的字段：13 sub 标签（网申常问且没填时 #C9711C），距输入框 8；标签右侧可放灰字动作。</summary>
    static StackPanel Field(string label, UIElement control, bool asked = false, (string Title, Action Action)? action = null) =>
        Field(Sans(label, 13, asked ? Asked : Sub), control, action);

    static StackPanel Field(TextBlock label, UIElement control, (string Title, Action Action)? action = null)
    {
        UIElement head = label;
        if (action is { } a) head = Spread(label, Sans(a.Title, 12, Faint).OnTap(a.Action, a.Title), 12);
        return VStack(8, head, control);
    }

    /// <summary>输入框（Windows TextBox 32 高）：离开或回车时内容变了才保存，Esc 还原。</summary>
    static TextBox TextInput(string label, string value, string? placeholder, Action<string> commit, bool digits = false, bool clearAfterCommit = false)
    {
        var box = Input(placeholder ?? "", value);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, label);
        var baseline = value;
        if (digits) box.BeforeTextChanging += (_, e) => { if (e.NewText.Any(c => !char.IsDigit(c))) e.Cancel = true; };
        void Send()
        {
            var trimmed = box.Text.Trim();
            if (trimmed != baseline.Trim()) { if (!clearAfterCommit) baseline = trimmed; commit(box.Text); }
            if (clearAfterCommit) box.Text = "";
        }
        box.LostFocus += (_, _) => Send();
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Send(); }
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; box.Text = baseline; }
        };
        return box;
    }

    /// <summary>多行输入：88 高，离开时内容变了才保存。</summary>
    static TextBox TextArea(string label, string value, Action<string> commit)
    {
        var box = Input("", value, 4000, multiline: true);
        box.Height = 88;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, label);
        var baseline = value;
        box.LostFocus += (_, _) => { var trimmed = box.Text.Trim(); if (trimmed != baseline) { baseline = trimmed; commit(trimmed); } };
        return box;
    }

    /// <summary>下拉（ComboBox 外观：32 高、圆角 4、Cl 描边、右侧小箭头），选项来自 MenuFlyout。</summary>
    static Border Select(string label, string value, string[] options, Action<string> change)
    {
        var trigger = FieldBox(Sans(value.Length == 0 ? "请选择" : value, 14, value.Length == 0 ? Fnt2 : Txt), Icon("chevron.down", 10, Fnt));
        trigger.OnTap(() =>
        {
            var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
            foreach (var option in value.Length == 0 || options.Contains(value) ? options : options.Prepend(value).ToArray())
            {
                var item = new ToggleMenuFlyoutItem { Text = option, IsChecked = option == value, MinWidth = trigger.ActualWidth };
                var picked = option;
                item.Click += (_, _) => { if (picked != value) change(picked); };
                menu.Items.Add(item);
            }
            menu.ShowAt(trigger);
        }, label);
        return trigger;
    }

    /// <summary>与输入框同外观的点击框：32 高、白底、圆角 4、Cl 描边 + 底部 1px 深一档。</summary>
    internal static Border FieldBox(UIElement text, UIElement trailing) => new()
    {
        Height = 32, CornerRadius = new CornerRadius(4), Background = Brush(White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1, 1, 1, 1),
        Padding = new Thickness(11, 0, 10, 0),
        Child = Columns(8, (Star(), text is FrameworkElement t ? t.Align(HorizontalAlignment.Left, VerticalAlignment.Center) : text),
            (Auto, trailing is FrameworkElement r ? r.Align(v: VerticalAlignment.Center) : trailing)),
    };

    UIElement PersonalField((string Key, string Label, string[]? Options, string? Placeholder, bool Date) row, JsonNode profile)
    {
        var value = profile["personal"].Text(row.Key);
        var title = profile["catalog"]?["fields"]?[$"profile.personal.{row.Key}"].Text("label") is { Length: > 0 } custom ? custom : row.Label;
        var asked = CareerProfileRules.Common.Contains(row.Key) && value.Length == 0;
        var label = Sans(title, 13, asked ? Asked : Sub);
        void Commit(string next)
        {
            if (CareerProfileRules.Common.Contains(row.Key)) label.Foreground = Brush(next.Trim().Length == 0 ? Asked : Sub);
            SavePersonal(row.Key, next);
        }
        UIElement control = row.Date ? DateFields.Birth(title, value, Commit)
            : row.Options is { } options ? Select(title, value, options, next => { Commit(next); Rerender(); })
            : TextInput(title, value, row.Placeholder, Commit);
        return Field(label, control);
    }

    /// <summary>证件号码：只写不读；已有时占位显示脱敏号码，标签右侧可删除。</summary>
    UIElement IdNumber(JsonNode profile)
    {
        var has = profile.Bool("has_id_number");
        var box = TextInput("证件号码", "", has ? profile.Text("id_number_masked") : "证件号码", number =>
        {
            var trimmed = number.Trim();
            if (trimmed.Length == 0) return;
            var type = profile.Text("id_type") is { Length: > 0 } t ? t : profile["catalog"]?["id_types"].Items().FirstOrDefault()?.GetValue<string>() ?? "";
            Save(_ => new() { ["id_type"] = type, ["id_number"] = trimmed }, true);
        }, clearAfterCommit: true);
        return Field("证件号码", box, !has, has ? ("删除", () => Save(_ => new() { ["id_number"] = "" }, true)) : null);
    }

    /// <summary>求职意向：期望城市（顿号分开）、期望薪资（K / 月，最低–最高）、工作性质。</summary>
    UIElement IntentFields(JsonNode intent)
    {
        string ToK(string key) => intent.Number(key) is { } value ? Math.Round(value / 1000).ToString("0") : "";
        var types = intent.Items("employment_types").Select(x => x.GetValue<string>()).ToArray();
        var kind = types.Length >= 2 ? "both" : types.FirstOrDefault() ?? "";
        (string id, string label)[] kinds = [("internship", "实习"), ("full_time", "全职"), ("both", "实习和全职都可以")];
        var cities = string.Join("、", intent.Items("candidate_cities").Select(x => x.GetValue<string>()));
        var low = TextInput("最低", ToK("salary_min"), "最低", _ => { }, digits: true);
        var high = TextInput("最高", ToK("salary_max"), "最高", _ => { }, digits: true);
        // 两个框共用一次保存：任一框提交时都把两个框的当前值一起写回
        low.LostFocus += (_, _) => SaveSalary(low.Text, high.Text);
        high.LostFocus += (_, _) => SaveSalary(low.Text, high.Text);
        return TwoColumns([
            Cell(Field("期望城市", TextInput("期望城市", cities, "用顿号分开，例如 杭州、上海", text =>
            {
                var list = text.Split(['、', ',', '，', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Take(20);
                SaveIntent(new() { ["candidate_cities"] = new JsonArray(list.Select(x => (JsonNode?)x).ToArray()) });
            }))),
            Cell(Field("期望薪资（K / 月）", Columns(10, (Star(), low), (Auto, Sans("–", 14, Fnt).Align(v: VerticalAlignment.Center)), (Star(), high)))),
            Cell(Field("工作性质", Select("工作性质", kinds.FirstOrDefault(x => x.id == kind).label ?? "", kinds.Select(x => x.label).ToArray(), label =>
            {
                var picked = kinds.First(x => x.label == label).id;
                SaveIntent(new() { ["employment_types"] = new JsonArray((picked == "both" ? new[] { "internship", "full_time" } : new[] { picked }).Select(x => (JsonNode?)x).ToArray()) }, true);
            }))),
        ]);
    }

    string _lastSalary = "";
    void SaveSalary(string lowText, string highText)
    {
        var key = lowText.Trim() + "|" + highText.Trim();
        var initial = _intent is { } i ? $"{(i.Number("salary_min") is { } a ? Math.Round(a / 1000).ToString("0") : "")}|{(i.Number("salary_max") is { } b ? Math.Round(b / 1000).ToString("0") : "")}" : "";
        if (key == (_lastSalary.Length > 0 ? _lastSalary : initial)) return;
        _lastSalary = key;
        double? min = double.TryParse(lowText, out var l) ? l * 1000 : null, max = double.TryParse(highText, out var h) ? h * 1000 : null;
        var has = min is not null || max is not null;
        var top = max is { } mx && min is { } mn && mx < mn ? min : max;
        SaveIntent(new()
        {
            ["salary_min"] = min, ["salary_max"] = top,
            ["salary_currency"] = has ? "CNY" : null, ["salary_period"] = has ? "month" : null,
        });
    }

    // MARK: 经历

    void Experiences()
    {
        var experience = Experience;
        var supplements = experience["supplements"];
        foreach (var group in ProfileModel.Groups(experience, _drafts))
        {
            var items = new StackPanel();
            for (var index = 0; index < group.Items.Count; index++)
            {
                var item = group.Items[index];
                var id = item.Entry.Text("id");
                var form = EntryForm(index, item.Kind, item.Entry, supplements?[id] as JsonObject ?? [],
                    update => Save(current => new() { ["experience"] = ProfileModel.ApplyEntry(ProfileModel.ExperienceOf(current), id, update, (group.Key, group.Label)) }),
                    () =>
                    {
                        if (ProfileModel.SavedIds(Experience).Contains(id)) Save(current => new() { ["experience"] = ProfileModel.RemoveEntry(ProfileModel.ExperienceOf(current), id) }, true);
                        else { _drafts.RemoveAll(x => x.Id == id); Rerender(); }
                    });
                if (index > 0)
                {
                    var dash = new Microsoft.UI.Xaml.Shapes.Line { X1 = 0, X2 = 2000, Stroke = Brush(Line), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 4, 3 }, Margin = new Thickness(0, 28, 0, 0) };
                    items.Children.Add(new Border { Child = dash, Height = 29, HorizontalAlignment = HorizontalAlignment.Stretch });
                }
                items.Children.Add(form);
            }
            var key = group.Key;
            (string, Action)? add = group.Addable ? ($"添加{group.Label}", () => { _drafts.Add((ProfileModel.NewId(), key)); Rerender(); }) : null;
            _column.Children.Add(Section(group.Label, ProfileModel.GroupDescriptions.GetValueOrDefault(group.Key), add, items));
        }
    }

    /// <summary>一段经历：「第 N 段」+ 右侧「删除」（再点一次确认）；下面是两栏输入框和描述。</summary>
    UIElement EntryForm(int index, string kind, JsonNode entry, JsonObject supplement, Action<ProfileModel.Update> change, Action remove)
    {
        var inputs = ProfileModel.Inputs.GetValueOrDefault(kind, []).ToList();
        var known = inputs.Where(x => x.Field is not null).Select(x => x.Field!).ToHashSet();
        // 简历里读进来、这里没有专门输入框的项（例如所属单位、导师）也照样能改
        if (entry["fields"] is JsonObject fields)
            inputs.AddRange(fields.Select(x => x.Key).Order(StringComparer.Ordinal).Where(x => !known.Contains(x) && fields.Text(x).Length > 0).Select(x => new ProfileModel.EntryInput(x, x)));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        void Idle()
        {
            actions.Children.Clear();
            actions.Children.Add(Sans("删除", 12, Faint).OnTap(Confirming, "删除这一段"));
        }
        void Confirming()
        {
            actions.Children.Clear();
            actions.Children.Add(Sans("确认删除", 12, Red).OnTap(remove, "确认删除"));
            actions.Children.Add(Sans("取消", 12, Faint).OnTap(Idle, "取消"));
        }
        Idle();

        string Value(ProfileModel.EntryInput input)
        {
            if (input.Gpa)
            {
                var gpa = supplement.Text("gpa"); var scale = supplement.Text("gpa_scale");
                return gpa.Length == 0 ? "" : scale.Length == 0 ? gpa : $"{gpa} / {scale}";
            }
            if (input.Supplement is { } key && supplement.Text(key) is { Length: > 0 } value) return value;
            return input.Field is { } field ? entry["fields"].Text(field) : "";
        }

        void Commit(ProfileModel.EntryInput input, string raw)
        {
            var value = raw.Trim();
            (string Value, string? Scale)? gpa = null;
            if (input.Gpa && value.Length > 0)
            {
                var match = Regex.Match(value, @"^(\d{1,9}(?:\.\d{1,4})?)\s*(?:[\/／]\s*(\d{1,9}(?:\.\d{1,4})?))?$");
                if (!match.Success) { V3Toast.Show("没有保存", V3Toast.Kind.Error, "GPA 写成 3.6 或 3.6 / 4.0。"); return; }
                gpa = (match.Groups[1].Value, match.Groups[2].Success ? match.Groups[2].Value : null);
            }
            change((current, currentSupplement) =>
            {
                var result = new ProfileModel.Change();
                if (input.Gpa)
                {
                    var next = (JsonObject)currentSupplement.DeepClone();
                    next.Remove("gpa"); next.Remove("gpa_scale");
                    if (gpa is { } g) { next["gpa"] = g.Value; if (g.Scale is { } s) next["gpa_scale"] = s; }
                    return result with { Supplement = next };
                }
                if (input.Supplement is { } key)
                {
                    var next = (JsonObject)currentSupplement.DeepClone();
                    if (value.Length == 0) next.Remove(key); else next[key] = value;
                    result = result with { Supplement = next };
                }
                if (input.Field is { } field && (input.Supplement is null || current["fields"]?[field] is not null))
                {
                    var next = current["fields"] is JsonObject f ? (JsonObject)f.DeepClone() : [];
                    if (value.Length == 0) next.Remove(field); else next[field] = value;
                    result = result with { Fields = next };
                }
                return result;
            });
        }

        var cells = inputs.Select(input =>
        {
            var current = Value(input);
            UIElement control = input.Month is { } month ? DateFields.YearMonth(input.Label, current, month == "end", next => Commit(input, next))
                : input.Options is { } options ? Select(input.Label, current, options, next => { Commit(input, next); Rerender(); })
                : TextInput(input.Label, current, input.Placeholder, next => Commit(input, next));
            return Cell(Field(input.Label, control), input.Wide);
        }).ToList();
        if (kind != "education" || entry.Text("description").Length > 0)
        {
            var label = ProfileModel.DescriptionLabels.GetValueOrDefault(kind, "描述");
            cells.Add(Cell(Field(label, TextArea(label, entry.Text("description"), next => change((_, _) => new ProfileModel.Change { Description = next }))), true));
        }
        return VStack(0, Spread(Sans($"第 {index + 1} 段", 12, Faint), actions, 12).Frame(height: 16).Top(index > 0 ? 0 : 4), TwoColumns(cells).Top(16));
    }

    // MARK: 技能

    /// <summary>技能胶囊：28 高、Cl 描边；名字 13 + 熟练度 12 灰；点一下切换（了解 → 熟悉 → 熟练 → 未标注），悬停换出 ×；最后一格虚线「＋ 添加技能」。</summary>
    UIElement Skills()
    {
        var skills = CareerProfileRules.Skills(Experience);
        var flow = new VariableSizedFlow(8);
        void SaveSkills(IEnumerable<CareerProfileRules.Skill> next) => Save(current =>
        {
            var experience = (JsonObject)ProfileModel.ExperienceOf(current).DeepClone();
            experience["skills"] = new JsonArray(next.Select(x => (JsonNode?)new JsonObject { ["name"] = x.Name, ["level"] = x.Level }).ToArray());
            return new() { ["experience"] = experience };
        }, true);
        var levels = CareerProfileRules.SkillLevels.Select(x => x.Id).ToList();
        foreach (var skill in skills)
        {
            var close = Icon("xmark", 9, Fnt);
            var remove = new Border { Width = 14, Height = 14, Background = Brush(Clear), Child = close.Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = 0 }
                .OnTap(() => SaveSkills(skills.Where(x => x.Name != skill.Name)), $"去掉 {skill.Name}");
            var level = CareerProfileRules.SkillLevels.FirstOrDefault(x => x.Id == skill.Level).Label ?? "未标注";
            var name = HStack(6, Sans(skill.Name, 13, Txt), Sans(level, 12, Fnt)).OnTap(() =>
            {
                var position = levels.IndexOf(skill.Level ?? "");
                SaveSkills(skills.Select(x => x.Name != skill.Name ? x : x with { Level = position == levels.Count - 1 ? null : levels[position + 1] }));
            }, $"{skill.Name}：{level}，点一下切换熟练度").Tip("点一下切换熟练度");
            var pill = new Border
            {
                Height = 28, Padding = new Thickness(12, 0, 10, 0), CornerRadius = new CornerRadius(14), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Background = Brush(White),
                Child = HStack(6, name.Align(v: VerticalAlignment.Center), remove.Align(v: VerticalAlignment.Center)),
            };
            pill.OnHover(h => remove.Opacity = h ? 1 : 0);
            flow.Add(pill);
        }
        // 「＋ 添加技能」：点开换成就地输入框，顿号分开，回车确定
        var addSlot = new ContentControl();
        void ShowAdd()
        {
            var dashed = new Microsoft.UI.Xaml.Shapes.Rectangle { RadiusX = 14, RadiusY = 14, Stroke = Brush(Sk2), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 2 } };
            var label = HStack(4, Icon("plus", 10, Sub), Sans("添加技能", 13, Sub)).Pad(12, 0, 12, 0);
            label.VerticalAlignment = VerticalAlignment.Center;
            var cell = new Grid { Height = 28, Children = { dashed, label } };
            addSlot.Content = cell.OnTap(ShowInput, "添加技能");
        }
        void ShowInput()
        {
            var box = Input("用顿号分开，回车确定", "");
            box.Width = 220;
            var done = false;
            void Add()
            {
                if (done) return;
                done = true;
                var known = skills.Select(x => x.Name.ToLowerInvariant()).ToHashSet();
                var seen = new HashSet<string>();
                var added = box.Text.Split(['、', ',', '，', ';', '；', '/', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                    .Where(x => x.Length <= 60 && !known.Contains(x.ToLowerInvariant()) && seen.Add(x.ToLowerInvariant())).ToList();
                if (added.Count > 0) SaveSkills(skills.Concat(added.Select(x => new CareerProfileRules.Skill(x, "familiar"))).Take(60));
                else ShowAdd();
            }
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Add(); }
                if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; done = true; ShowAdd(); }
            };
            box.LostFocus += (_, _) => Add();
            box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
            addSlot.Content = box;
        }
        ShowAdd();
        flow.Add(addSlot);
        return flow.Panel;
    }

    // MARK: 保存

    void Rerender() { if (!_disposed) Render(); }

    /// <summary>连续失焦会各自保存一次：排队依次提交，每次都拿上一次保存后的最新画像（含版本号）算改动。</summary>
    void Enqueue(Func<Task> work)
    {
        var previous = _queue;
        _queue = Run();
        async Task Run()
        {
            try { await previous; } catch { }
            _saving++; UpdateStatus();
            try { await work(); }
            finally { _saving--; UpdateStatus(); }
        }
    }

    async Task FailAsync(Exception error)
    {
        var code = (error as ApiException)?.Code ?? "";
        var message = ErrorText.From(error, "请检查填写内容后重试。", new Dictionary<string, string>
        {
            ["AUTOFILL_ID_STORAGE_UNAVAILABLE"] = "证件号码暂时无法保存，请稍后再试。",
            ["USER_PROFILE_VERSION_CONFLICT"] = "画像在别处改过了，已刷新为最新内容，请再改一次。",
            ["RESUME_NOT_FOUND"] = "这份简历不存在或已删除。",
        });
        V3Toast.Show("没有保存", V3Toast.Kind.Error, message);
        if (code == "USER_PROFILE_VERSION_CONFLICT") await LoadAsync();
    }

    /// <summary>写 `/api/account/career-profile`；<paramref name="rerender"/> 为 true 时保存后重画（结构变化），否则只更新页头状态，不打断正在输入的框。</summary>
    void Save(Func<JsonNode, JsonObject> change, bool rerender = false) => Enqueue(async () =>
    {
        if (_profile is not { } current) return;
        var body = change(current);
        body["base_lock_version"] = current["lock_version"]?.DeepClone() ?? JsonValue.Create(1);
        try
        {
            _profile = await AccountPage.Request("/api/account/career-profile", "PUT", body);
            var saved = ProfileModel.SavedIds(Experience);
            _drafts.RemoveAll(x => saved.Contains(x.Id));
            if (rerender) Rerender();
            else UpdateStatus();
        }
        catch (Exception error) { await FailAsync(error); }
    });

    void SavePersonal(string key, string value) => Save(current =>
    {
        var personal = current["personal"] is JsonObject p ? (JsonObject)p.DeepClone() : [];
        var trimmed = value.Trim();
        if (trimmed.Length == 0) personal.Remove(key);
        else personal[key] = ProfileModel.UrlKeys.Contains(key) ? ProfileModel.WithScheme(trimmed) : trimmed;
        return new() { ["personal"] = personal };
    });

    /// <summary>求职意向走 `/api/account/user-profile`：先读最新版本，合并改动后整体写回。</summary>
    void SaveIntent(JsonObject change, bool rerender = false) => Enqueue(async () =>
    {
        try
        {
            if (await AccountPage.Request("/api/account/user-profile") is not JsonObject latest) return;
            var version = latest["lock_version"]?.DeepClone() ?? JsonValue.Create(1);
            latest.Remove("lock_version"); latest.Remove("created_at"); latest.Remove("updated_at");
            foreach (var (key, value) in change) latest[key] = value?.DeepClone();
            latest["base_lock_version"] = version;
            _intent = await AccountPage.Request("/api/account/user-profile", "PUT", latest);
            if (rerender) Rerender();
        }
        catch (Exception error) { await FailAsync(error); }
    });
}

/// <summary>求职画像的输入项与经历改写（对齐 Web `CareerProfilePage.tsx` 的 ENTRY_INPUTS / applyEntryChange / removeEntry）。</summary>
static class ProfileModel
{
    public static readonly (string Key, string Label, string[]? Options, string? Placeholder, bool Date)[] Basic =
    [
        ("name", "姓名", null, null, false), ("gender", "性别", ["男", "女", "其他", "不愿透露"], null, false),
        ("birth_date", "出生日期", null, null, true), ("phone", "手机号", null, null, false),
        ("email", "邮箱", null, null, false), ("github", "GitHub", null, "主页地址或用户名", false),
        ("website", "个人网站", null, "主页地址", false), ("portfolio_url", "作品链接", null, "作品集或网盘链接", false),
    ];
    public static readonly (string Key, string Label, string[]? Options, string? Placeholder, bool Date)[] Identity =
    [
        ("ethnicity", "民族", null, "例如 汉族", false),
        ("political_status", "政治面貌", ["中共党员", "中共预备党员", "共青团员", "群众", "其他"], null, false),
        ("native_place", "籍贯", null, "例如 江苏南京", false), ("home_city", "家庭所在城市", null, null, false),
    ];
    public static readonly HashSet<string> UrlKeys = ["website", "portfolio_url"];

    public static string WithScheme(string value)
    {
        var match = Regex.Match(value, "^https?://", RegexOptions.IgnoreCase);
        return match.Success ? match.Value.ToLowerInvariant() + value[match.Length..] : "https://" + value;
    }

    public sealed record EntryInput(string Label, string? Field = null, string? Supplement = null, string? Placeholder = null,
        string[]? Options = null, bool Wide = false, bool Gpa = false, string? Month = null);

    public static readonly Dictionary<string, EntryInput[]> Inputs = new()
    {
        ["education"] =
        [
            new("学校", "学校"), new("学院", "学院"),
            new("学历学位", "学历学位", Options: ["博士", "硕士", "本科", "大专", "高中"]), new("专业", "专业"),
            new("开始时间", "开始时间", Month: "start"), new("结束时间", "结束时间", Month: "end"),
            new("GPA", Supplement: "gpa", Placeholder: "例如 3.6 / 4.0", Gpa: true), new("专业排名", Supplement: "major_rank", Placeholder: "例如 5 / 120"),
            new("主修课程", "主修课程", Placeholder: "用顿号分开，例如 数据结构、操作系统", Wide: true),
        ],
        ["work"] =
        [
            new("公司名称", "单位"), new("部门", "部门", "department", "例如 交易平台部"),
            new("职位", "职位"), new("城市", "地点"),
            new("开始时间", "开始时间", Month: "start"), new("结束时间", "结束时间", Month: "end"),
        ],
        ["project"] =
        [
            new("项目名称", "项目名称"), new("角色", "角色"),
            new("开始时间", "开始时间", Month: "start"), new("结束时间", "结束时间", Month: "end"),
            new("链接", "链接", Placeholder: "作品或代码地址", Wide: true),
        ],
        ["other"] =
        [
            new("名称", "名称"), new("角色", "角色"),
            new("开始时间", "开始时间", Month: "start"), new("结束时间", "结束时间", Month: "end"),
        ],
    };
    public static readonly Dictionary<string, string> DescriptionLabels = new() { ["education"] = "在校经历", ["work"] = "工作内容", ["project"] = "项目描述", ["other"] = "描述" };
    static readonly (string Key, string Label)[] GroupLabels = [("education", "教育经历"), ("internship", "实习经历"), ("work", "工作经历"), ("project", "项目经历"), ("campus", "校园经历"), ("other", "奖项与证书")];
    public static readonly Dictionary<string, string> GroupDescriptions = new()
    {
        ["education"] = "从最高学历填起，网申插件按这里填学校、专业和在校时间。", ["internship"] = "每段实习单独一份，网申插件逐段填表。",
        ["work"] = "全职工作经历，应届生可以先空着。", ["project"] = "课程、比赛、个人项目都可以，写清楚你负责的部分和结果。",
    };

    public static JsonObject EmptyExperience() => new()
    {
        ["schema_version"] = 1, ["extra_basics"] = new JsonObject(), ["sections"] = new JsonArray(),
        ["supplements"] = new JsonObject(), ["records"] = new JsonObject(), ["skills"] = new JsonArray(),
    };

    public static JsonObject ExperienceOf(JsonNode profile) => profile["experience"] is JsonObject value ? value : EmptyExperience();

    public static string NewId() => "e_" + Base36(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) + Guid.NewGuid().ToString("N")[..6];
    static string Base36(long value)
    {
        const string digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        var text = "";
        do { text = digits[(int)(value % 36)] + text; value /= 36; } while (value > 0);
        return text;
    }

    public sealed record Item(JsonNode Entry, string Kind);
    public sealed record Group(string Key, string Label, bool Addable, List<Item> Items);

    public static List<Group> Groups(JsonNode experience, IEnumerable<(string Id, string Group)> drafts)
    {
        var result = GroupLabels.Select(x => new Group(x.Key, x.Label, x.Key is not ("campus" or "other"), [])).ToList();
        foreach (var section in experience.Items("sections"))
        {
            var raw = section.Text("kind");
            if (CareerProfileRules.TextKinds.Contains(raw)) continue;
            var kind = CareerProfileRules.EntryKind(raw);
            foreach (var entry in section.Items("entries"))
            {
                var key = kind == "work" ? (entry.Bool("intern") ? "internship" : "work") : raw == "activity" ? "campus" : kind;
                result.FirstOrDefault(x => x.Key == key)?.Items.Add(new(entry, kind));
            }
        }
        foreach (var (id, group) in drafts)
        {
            var kind = group is "internship" or "work" ? "work" : CareerProfileRules.EntryKind(group);
            var entry = new JsonObject { ["id"] = id, ["fields"] = new JsonObject(), ["description"] = "", ["ambiguous"] = new JsonArray(), ["intern"] = group == "internship" };
            result.FirstOrDefault(x => x.Key == group)?.Items.Add(new(entry, kind));
        }
        return result.Where(x => x.Addable || x.Items.Count > 0).ToList();
    }

    public static HashSet<string> SavedIds(JsonNode experience) =>
        experience.Items("sections").SelectMany(x => x.Items("entries")).Select(x => x.Text("id")).ToHashSet();

    /// <summary>一段经历的改动：字段、描述、网申补充；null 表示不改这一项。</summary>
    public sealed record Change
    {
        public JsonObject? Fields { get; init; }
        public string? Description { get; init; }
        public JsonObject? Supplement { get; init; }
    }

    public delegate Change? Update(JsonNode entry, JsonObject supplement);

    /// <summary>把一段经历的改动写回整份经历；这段还不存在时（刚点了添加），第一次保存才放进对应分组。</summary>
    public static JsonObject ApplyEntry(JsonObject experience, string id, Update update, (string Group, string Label) create)
    {
        var root = (JsonObject)experience.DeepClone();
        var sections = root["sections"] as JsonArray ?? [];
        root["sections"] = sections;
        var current = sections.SelectMany(x => x.Items("entries")).FirstOrDefault(x => x.Text("id") == id);
        var intern = create.Group == "internship";
        var entry = current is not null ? (JsonObject)current.DeepClone()
            : new JsonObject { ["id"] = id, ["fields"] = new JsonObject(), ["description"] = "", ["ambiguous"] = new JsonArray(), ["intern"] = intern };
        var supplements = root["supplements"] as JsonObject ?? [];
        root["supplements"] = supplements;
        var existing = supplements[id] is JsonObject value ? (JsonObject)value.DeepClone() : [];
        if (update(entry, existing) is not { } change) return experience;
        if (change.Supplement is { } nextSupplement)
        {
            if (nextSupplement.Count == 0) supplements.Remove(id); else supplements[id] = nextSupplement.DeepClone();
        }
        if (change.Fields is { } fields)
        {
            entry["fields"] = fields.DeepClone();
            entry["ambiguous"] = new JsonArray(entry.Items("ambiguous").Where(x => fields.Text(x.GetValue<string>()).Length == 0).Select(x => x.DeepClone()).ToArray());
        }
        if (change.Description is { } description) entry["description"] = description;

        if (current is not null)
        {
            foreach (var section in sections.OfType<JsonObject>())
                if (section["entries"] is JsonArray entries)
                    for (var i = 0; i < entries.Count; i++)
                        if (entries[i].Text("id") == id) entries[i] = entry.DeepClone();
        }
        else
        {
            var kind = intern ? "work" : create.Group;
            var same = sections.OfType<JsonObject>().Where(x => x.Text("kind") == kind).ToList();
            // 实习和工作都在 work 分组里：优先放进标题对得上的那一组
            var target = (kind == "work" ? same.FirstOrDefault(x => x.Text("title").Contains("实习") == intern) : null) ?? same.FirstOrDefault();
            if (target is not null)
            {
                if (target["entries"] is not JsonArray entries) target["entries"] = entries = [];
                entries.Add(entry);
            }
            else sections.Add(new JsonObject { ["id"] = "", ["kind"] = kind, ["title"] = create.Label, ["lines"] = new JsonArray(), ["entries"] = new JsonArray(entry) });
        }
        return root;
    }

    public static JsonObject RemoveEntry(JsonObject experience, string id)
    {
        var root = (JsonObject)experience.DeepClone();
        (root["supplements"] as JsonObject)?.Remove(id);
        foreach (var section in (root["sections"] as JsonArray ?? []).OfType<JsonObject>())
            if (section["entries"] is JsonArray entries)
                for (var i = entries.Count - 1; i >= 0; i--)
                    if (entries[i].Text("id") == id) entries.RemoveAt(i);
        return root;
    }
}
