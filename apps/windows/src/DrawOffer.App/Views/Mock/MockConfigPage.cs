using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>复盘报告「练这几题 / 练这一处」带到配置页的一项（Windows 稿 09 · 10.08、10.09；Web `practicePlan.ts`）。</summary>
public sealed record MockPracticeItem(string Label, string Question, IReadOnlyList<string> Signals, string? Note, string? Tag, string Last, string Goal);

public sealed record MockPracticePlan(string Back, IReadOnlyList<MockPracticeItem> Items, string? ApplicationId, string? InterviewType, string? Difficulty, string? Mode, string? ResumeId);

/// <summary>
/// 这一场怎么练（Windows 稿 09 · 02.01 面试配置、02.02 选岗位、02.03 选简历、02.04 面试类型、02.05 更多设置；Mac `MockConfigPage`、Web `v2/ConfigPage.tsx`）。
/// 左边两张方案卡（第一场 / 接着练 / 完整模拟），右边六行设置；没有任何记录时每行下面多一行灰字说明。
/// </summary>
public sealed class MockConfigPage : UserControl
{
    const int ContinueCount = 3, FullCount = 8, FirstCount = 3, PerQuestion = 5;
    static readonly string[] Types = ["technical", "project_deep_dive", "comprehensive", "hr"];
    static readonly Dictionary<string, string> TypeHints = new()
    {
        ["technical"] = "考专业知识的原理与实际情境处理",
        ["project_deep_dive"] = "只追问简历里的经历，层层深挖",
        ["comprehensive"] = "专业、项目与软素质各问一些",
        ["hr"] = "动机、职业规划、协作与薪资期望",
    };
    static readonly string[] FirstHintsTail = ["就用你刚写好的这份", "技术和项目都会问，最容易看出哪里要补", "按你的经验定的，答不上来也没关系"];

    enum Plan { First, Resume, Full }

    readonly PracticeFocus? _focus;
    readonly MockPracticePlan? _practice;
    readonly Action _back, _showBoard, _showOpportunities;
    readonly Action<string> _open;
    readonly MockViewLifetime _life;
    readonly Border _host = new();

    List<JsonNode> _list = [], _applications = [], _sessions = [], _resumes = [], _voices = [], _prices = [];
    JsonNode? _overview;
    Dictionary<string, string> _defaultVoices = [];
    string? _targetRole;
    bool _loaded, _failed, _speech, _applied, _submitting, _followUp = true;
    DateTimeOffset _now = Beijing.Now;
    string? _chosen, _type;
    Plan? _plan;
    string _difficulty = "intermediate", _mode = "voice", _voice = "male", _language = "zh", _resume = "";
    Dictionary<string, string> _voiceIds = [];

    public MockConfigPage(PracticeFocus? focus, MockPracticePlan? practice, Action back, Action<string> open, Action showBoard, Action showOpportunities)
    {
        (_focus, _practice, _back, _open, _showBoard, _showOpportunities) = (focus, practice, back, open, showBoard, showOpportunities);
        _life = new MockViewLifetime(this, back);
        Content = new ScrollViewer { Content = _host, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Background = Brush(V3.White);
        SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) Render(); };
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    // 派生

    MockMap.Target Target => _loaded
        ? MockMap.PickTarget(_applications, _sessions, _now, _chosen ?? _practice?.ApplicationId ?? "general")
        : new MockMap.Target(MockMap.TargetKind.General, null, null);
    JsonNode? Stuck => _overview.Get("stuck") is JsonObject stuck ? stuck : null;
    string? Topic => _focus?.Label ?? Stuck.Text("topic").NonEmpty();
    bool CanContinue => Topic is not null;
    /// <summary>这个账号还没有任何能算数的面试：第一场按说明出，默认 3 题先走一遍。</summary>
    bool FirstTime => _loaded && _practice is null && _focus is null && !_list.Any(x => x.Text("status") is "in_progress" or "evaluating" or "evaluation_failed" or "completed");
    Plan ActivePlan => _plan ?? (FirstTime ? Plan.First : CanContinue ? Plan.Resume : Plan.Full);
    int Count => _practice?.Items.Count ?? (ActivePlan == Plan.First ? FirstCount : ActivePlan == Plan.Resume ? ContinueCount : FullCount);
    string StageLabel => Target.Session.Text("stage_label").NonEmpty() ?? Target.Application.Text("current_stage_label");
    string ActiveType => _type ?? (StageLabel.Trim().ToUpperInvariant().StartsWith("HR", StringComparison.Ordinal) ? "hr" : "comprehensive");
    JsonNode? Blocking => _list.FirstOrDefault(x => x.Text("status") is "in_progress" or "preparing" or "evaluating" or "evaluation_failed");
    JsonNode? SelectedResume => _resumes.FirstOrDefault(x => x.Display("id") == _resume);
    string CompanyName => Target.Application.Text("company_name_snapshot").NonEmpty() ?? Target.Session.Text("company_name");
    string JobLabel => Target.Kind == MockMap.TargetKind.General ? "只按简历出题"
        : string.Join(" · ", new[] { CompanyName, Target.Application.Text("job_title_snapshot"), StageLabel }.Where(x => x.Length > 0));
    List<JsonNode> BoardJobs => _applications.Where(x => x.Text("status") == "active" && x.Text("archived_at").Length == 0).ToList();

    string? Cost
    {
        get
        {
            JsonNode? Price(string code) => _prices.FirstOrDefault(x => x.Text("featureCode") == code);
            static double? Unit(JsonNode? value) => value.Get("unitPoints") is { } raw ? raw.Number() ?? (raw is JsonValue v && v.TryGetValue<string>(out var s) && double.TryParse(s, out var d) ? d : null) : null;
            var text = Price("mock_interview");
            var voicePrice = _mode == "voice" ? Price("mock_interview_voice") : null;
            switch (text.Text("priceMode"))
            {
                case "free": return "本次免费";
                case "usage": return "按实际用量计积分";
                case "fixed":
                    if (Unit(text) is not { } basis) return null;
                    if (voicePrice.Text("priceMode") == "free") return "本次免费";
                    var each = voicePrice.Text("priceMode") == "fixed" ? Unit(voicePrice) ?? basis : basis;
                    var total = Math.Round(each * Count * 100) / 100;
                    return $"消耗 {(total == Math.Round(total) ? $"{(long)total}" : $"{total}")} 积分";
                default: return null;
            }
        }
    }

    string Title => _practice is { } practice
        ? practice.Items.Count > 1 ? $"接着练这 {practice.Items.Count} 题" : $"练这一处：{practice.Items.FirstOrDefault()?.Label}"
        : FirstTime ? "第一场，先这样练" : "这一场怎么练？";

    string Desc => _practice is { } practice
        ? practice.Items.Count > 1 ? "从你上次停下的地方问起，设置沿用上一场，也可以改。" : "只问这一处，从上次停下的地方接着追问。"
        : FirstTime ? "第一次练，每一项都按你的情况选好了，右边写了为什么。"
        : CanContinue ? "默认从你卡住的地方接着问，其他都可以改。" : "第一场先走一遍完整流程，其他都可以改。";

    // 画面

    void Render()
    {
        var width = ActualWidth > 0 ? ActualWidth : 1180;
        var gutter = V3Page.Gutter(width);
        var back = HStack(5, Icon("chevron.left", 10, MP.Fnt), Sans(_practice?.Back ?? "模拟面试", 13, MP.Fnt)).OnTap(_back, "返回" + (_practice?.Back ?? "模拟面试"));
        back.HorizontalAlignment = HorizontalAlignment.Left;

        var body = new StackPanel { MaxWidth = 824, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 64, 0, 0) };
        body.Children.Add(Label(Title, 36, MP.Ink, Semibold).Frame(height: 50).Also(t => AutomationProperties.SetHeadingLevel(t, AutomationHeadingLevel.Level1)));
        body.Children.Add(Sans(Desc, 14, MP.Sub).Frame(height: 22).Top(10));
        if (_failed) body.Children.Add(Sans("设置没有加载出来，请刷新后重试。", 13, MP.Fnt).Top(30));
        else if (!_loaded) body.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 30, 0, 0) });
        else
        {
            FrameworkElement left = _practice is { } practice ? PracticeCard(practice.Items) : Plans();
            var narrow = width - gutter * 2 < 780;
            FrameworkElement columns = narrow
                ? VStack(28, left, Settings())
                : Columns(48, (Px(375), left), (Star(), Settings()));
            body.Children.Add(columns.Top(30));
            var cost = string.Join(" · ", new[] { $"{Count} 题，约 {Count * PerQuestion} 分钟", Cost }.OfType<string>());
            var start = MP.Dark(_submitting ? "正在准备…" : Blocking is not null ? "继续上一场" : "开始面试", () => _ = StartAsync(), 32, !_submitting);
            var foot = Columns(18, (Star(), Sans(cost, 13, MP.Fnt).Align(v: VerticalAlignment.Center)),
                (Auto, MP.Link("更多设置 ›", More).Align(v: VerticalAlignment.Center)), (Auto, start));
            body.Children.Add(new Border { Child = foot, Margin = new Thickness(0, 20, 0, 0), Padding = new Thickness(0, 28, 0, 0), BorderBrush = Brush(MP.Line), BorderThickness = new Thickness(0, 1, 0, 0) });
        }
        _host.Padding = new Thickness(gutter, 52, gutter, 60);
        _host.Child = VStack(0, back, body);
    }

    FrameworkElement Plans()
    {
        var stack = new StackPanel { Spacing = 16 };
        if (FirstTime)
            stack.Children.Add(PlanCard(ActivePlan == Plan.First, "第一次练", $"{FirstCount} 题，约 {FirstCount * PerQuestion} 分钟",
                "先自我介绍，再问两道简历里的事；\n走完一遍就有第一份报告。", false, () => { _plan = Plan.First; Render(); }));
        else
        {
            var others = _overview.Get("tallies").Get("open").Items("examples").Select(x => x is JsonValue v && v.TryGetValue<string>(out var s) ? s : "").Where(x => x.Length > 0 && x != Topic).Take(2).ToList();
            static bool Ascii(char c) => char.IsAscii(c) && char.IsLetterOrDigit(c);
            string text;
            if (Topic is not { } topic) text = "练完一场以后，\n这里会从你卡住的地方接着问。";
            else
            {
                var spaced = Ascii(topic[^1]) ? " " : "";
                if (others.Count == 0) text = $"从 {topic}{spaced}问起。";
                else
                {
                    var all = string.Join("和", others);
                    var also = all.Length <= 22 ? all : $"{others[0]} 等 {others.Count} 处";
                    text = $"从 {topic}{spaced}问起，\n再补{(Ascii(also[0]) ? " " : "")}{also}。";
                }
            }
            stack.Children.Add(PlanCard(ActivePlan == Plan.Resume, "接着练", $"{ContinueCount} 题，约 {ContinueCount * PerQuestion} 分钟", text, !CanContinue, () => { _plan = Plan.Resume; Render(); }));
        }
        stack.Children.Add(PlanCard(ActivePlan == Plan.Full, "完整模拟", $"{FullCount} 题，约 {FullCount * PerQuestion} 分钟",
            "先自我介绍，再按岗位走完一整场，\n卡住的地方也会问到。", false, () => { _plan = Plan.Full; Render(); }));
        return stack;
    }

    /// <summary>`.mi3-plan`：375 × 114，选中墨黑描边。</summary>
    static FrameworkElement PlanCard(bool on, string title, string meta, string text, bool disabled, Action action)
    {
        var head = Columns(12, (Star(), Label(title, 15, disabled ? MP.Mute : MP.Ink, Medium)), (Auto, Sans(meta, 12.5, MP.Sub).Align(v: VerticalAlignment.Center)));
        var card = new Border
        {
            Child = VStack(12, head, Sans(text, 12.5, disabled ? MP.Mute : MP.Sub).LineHeight(20).Wrap(2)),
            Height = 114, Padding = new Thickness(18, 18, 18, 16), CornerRadius = new CornerRadius(8),
            Background = Brush(V3.White), BorderBrush = Brush(on ? MP.Ink : MP.Cl), BorderThickness = new Thickness(on ? 1.5 : 1),
        };
        if (!disabled) card.OnTap(action, title);
        AutomationProperties.SetItemStatus(card, on ? "已选" : "");
        return card;
    }

    FrameworkElement Settings()
    {
        var stack = new StackPanel();
        stack.Children.Add(SetRow(0, "面试岗位", Drop(JobLabel, "面试岗位", 268, _ => Jobs())));
        stack.Children.Add(SetRow(1, "简历", Drop(SelectedResume.Text("title").NonEmpty() ?? "未选择", "简历", 192, ResumeMenu)));
        stack.Children.Add(SetRow(2, "面试类型", Drop(MockMap.TypeNames.GetValueOrDefault(ActiveType, "综合面"), "面试类型", 134, TypeMenu)));
        stack.Children.Add(SetRow(3, "难度", Seg("难度", ["junior", "intermediate", "senior"], x => MockMap.DiffName.GetValueOrDefault(x, x), _difficulty, v => _difficulty = v)));
        var answer = Seg("答题方式", ["voice", "text"], x => x == "voice" ? "语音" : "文字", _mode, v => _mode = v, disabledValue: _speech ? null : "voice");
        stack.Children.Add(SetRow(4, "答题方式", answer));
        var voice = Seg("面试官声音", ["male", "female"], x => x == "male" ? "男声" : "女声", _voice, v => _voice = v);
        voice.IsHitTestVisible = _mode == "voice";
        stack.Children.Add(SetRow(5, "面试官声音", voice, off: _mode != "voice"));
        return stack;
    }

    string FirstHint(int index) => index switch
    {
        0 => Target.Kind == MockMap.TargetKind.General ? "还没选岗位，先按简历里的方向出题" : "按这个岗位的要求出题",
        1 or 2 or 3 => FirstHintsTail[index - 1],
        4 => _mode == "voice" ? "最接近真实面试；不方便说话可以换成文字" : "用文字答；方便说话时换成语音更接近真实面试",
        _ => "只是声音不同，不影响出题",
    };

    /// <summary>`.mi3-set`：右列一行，左标签右控件，下面一条细线（最后一行没有）。</summary>
    FrameworkElement SetRow(int index, string label, FrameworkElement control, bool off = false)
    {
        var left = VStack(4, Sans(label, 13.5, MP.Sub));
        if (FirstTime) left.Children.Add(Sans(FirstHint(index), 12, MP.Hint).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        var row = Columns(16, (Star(), left.Align(v: VerticalAlignment.Center)), (Auto, control.Align(v: VerticalAlignment.Center)));
        row.Opacity = off ? 0.4 : 1;
        return new Border
        {
            Child = row, MinHeight = FirstTime ? 58 : 42, Padding = new Thickness(0, 5, 0, 5),
            BorderBrush = Brush(MP.Line), BorderThickness = new Thickness(0, 0, 0, index < 5 ? 1 : 0),
        };
    }

    /// <summary>ComboBox 观感的下拉：32 高、白底 #DCDCD8 细边、圆角 4，右侧下箭头。</summary>
    static FrameworkElement Drop(string text, string label, double maxWidth, Action<FrameworkElement> open)
    {
        var content = Columns(10, (Star(), Sans(text, 13, MP.Ink).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Align(v: VerticalAlignment.Center)),
            (Auto, Icon("chevron.down", 10, MP.Sub).Align(v: VerticalAlignment.Center)));
        var box = new Border
        {
            Child = content, Height = 32, MaxWidth = maxWidth, Padding = new Thickness(11, 0, 11, 0), CornerRadius = new CornerRadius(4),
            Background = Brush(V3.White), BorderBrush = Brush(Sk2), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right,
        }.Tip(text);
        box.OnHover(h => box.Background = Brush(h ? MP.RowHover : V3.White));
        box.OnTap(() => open(box), $"{label}：{text}");
        return box;
    }

    FrameworkElement Seg(string label, string[] values, Func<string, string> name, string current, Action<string> pick, string? disabledValue = null)
    {
        var options = values.Where(v => v != disabledValue).Select(v => (v, name(v)));
        var seg = new V3Segmented<string>(options, current, height: 30, fontSize: 12.5).Tip(label);
        seg.Changed += value => { pick(value); Render(); };
        return seg;
    }

    void ResumeMenu(FrameworkElement anchor)
    {
        Flyout? flyout = null;
        var menu = new StackPanel { Width = 260 };
        foreach (var item in _resumes)
        {
            var id = item.Display("id");
            var on = id == _resume;
            var row = Columns(12, (Star(), Sans(item.Text("title"), 13.5, MP.Ink, on ? Medium : Regular).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis)),
                (Auto, Sans(MockMap.MmddDot(item.Text("updated_at")).Replace("·", "-"), 12, MP.Mute)));
            menu.Children.Add(MenuRow(row, on, () => { flyout?.Hide(); _resume = id; Render(); }));
        }
        AutomationProperties.SetName(menu, "选择简历");
        flyout = V3Popover.Show(anchor, menu, Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight, 6);
    }

    void TypeMenu(FrameworkElement anchor)
    {
        Flyout? flyout = null;
        var menu = new StackPanel { Width = 300 };
        foreach (var value in Types)
        {
            var on = value == ActiveType;
            var row = VStack(1, Sans(MockMap.TypeNames.GetValueOrDefault(value, ""), 13.5, MP.Ink, on ? Medium : Regular), Sans(TypeHints[value], 12.5, MP.Fnt));
            menu.Children.Add(MenuRow(row, on, () => { flyout?.Hide(); _type = value; Render(); }));
        }
        AutomationProperties.SetName(menu, "面试类型");
        flyout = V3Popover.Show(anchor, menu, Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight, 6);
    }

    static FrameworkElement MenuRow(FrameworkElement content, bool on, Action action)
    {
        var row = new Border { Child = content, Padding = new Thickness(12, 9, 12, 9), CornerRadius = new CornerRadius(4), Background = Brush(on ? MP.Hover : Clear) };
        row.OnHover(h => row.Background = Brush(h || on ? MP.Hover : Clear));
        return row.OnTap(action);
    }

    /// <summary>左边要练的内容（Windows 稿 09 · 10.08 多题、10.09 一处）。</summary>
    static FrameworkElement PracticeCard(IReadOnlyList<MockPracticeItem> items)
    {
        var stack = new StackPanel();
        if (items.Count > 1)
        {
            for (var i = 0; i < items.Count; i++)
            {
                var item = items[i];
                var head = Columns(12, (Star(), Label(item.Label, 15, MP.Ink, Medium)), (Auto, item.Tag is null ? new Border() : Sans(item.Tag, 12, MP.Fnt)));
                var cell = VStack(4, head);
                if (item.Note is not null) cell.Children.Add(Sans(item.Note, 13, MP.Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
                stack.Children.Add(new Border
                {
                    Child = cell, Padding = new Thickness(0, 14, 0, 14), BorderBrush = Brush(MP.Line),
                    BorderThickness = new Thickness(0, 0, 0, i < items.Count - 1 ? 1 : 0),
                });
            }
            stack.Padding = new Thickness(20, 4, 20, 4);
        }
        else if (items.FirstOrDefault() is { } item)
        {
            stack.Spacing = 16;
            stack.Padding = new Thickness(20, 18, 20, 18);
            if (item.Signals.Count > 0)
            {
                var chips = HStack(6, item.Signals.Take(3).Select(signal => (UIElement)new Border
                {
                    Child = Sans(signal, 12, MP.Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis), Padding = new Thickness(10, 3, 10, 3),
                    CornerRadius = new CornerRadius(4), Background = Brush(MP.Chip),
                }.Tip(signal)).ToArray());
                stack.Children.Add(VStack(6, Sans("要补", 12, MP.Fnt), chips));
            }
            stack.Children.Add(VStack(6, Sans("上次到哪", 12, MP.Fnt), Sans(item.Last, 13, MP.Sub).LineHeight(21).Wrap(2)));
            stack.Children.Add(VStack(6, Sans("这次要到", 12, MP.Fnt), Sans(item.Goal, 13, MP.Sub).LineHeight(21).Wrap(2)));
        }
        return new Border
        {
            Child = stack, MinHeight = 244, CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
            BorderBrush = Brush(MP.Cl), BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Top,
        };
    }

    // 弹窗

    void Jobs() => MockJobDialog.Show(XamlRoot, BoardJobs, _sessions, _now, Target.Kind == MockMap.TargetKind.General ? null : Target.Application.Display("id"),
        id => { _chosen = id ?? "general"; ApplyDefaults(); Render(); }, _showBoard, _showOpportunities);

    void More()
    {
        var merged = new Dictionary<string, string>(_defaultVoices);
        foreach (var (key, value) in _voiceIds) merged[key] = value;
        MockMoreDialog.Show(XamlRoot, _language, _followUp, _voice, _mode == "voice" ? _voices : [], merged, value =>
        {
            (_language, _followUp, _voiceIds) = (value.Language, value.FollowUp, value.VoiceIds);
            Render();
        });
    }

    // 加载与开始

    async Task LoadAsync()
    {
        if (App.Session.User is null) return;
        var since = DateTimeOffset.UtcNow.AddHours(-6).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        async Task<JsonNode?> Optional(string path, Dictionary<string, string>? query = null)
        {
            try { return await _life.Request(path, query: query); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { return null; }
        }
        try
        {
            var list = _life.Request("/api/mock-interviews", query: new() { ["limit"] = "100" });
            var resumes = _life.Request("/api/resumes");
            var overview = Optional("/api/mock-interviews/overview");
            var applications = Optional("/api/job-applications", new() { ["scope"] = "active", ["limit"] = "200" });
            var sessions = Optional("/api/interview-sessions", new() { ["status"] = "scheduled", ["start_at"] = since, ["limit"] = "500" });
            var capability = Optional("/api/mock-interviews/speech-capability");
            var profile = Optional("/api/account/user-profile");
            var prices = Optional("/api/billing/feature-prices");
            _list = (await list).Items("items");
            _resumes = (await resumes).Items("resumes");
            _overview = await overview;
            _applications = (await applications).Items("items");
            _sessions = (await sessions).Items("items");
            var speech = await capability;
            _speech = speech.Get("stt").Bool() && speech.Get("tts").Bool();
            _voices = speech.Items("voices");
            _defaultVoices = speech.Get("default_voices") is JsonObject defaults
                ? defaults.Where(x => x.Value is JsonValue v && v.TryGetValue<string>(out _)).ToDictionary(x => x.Key, x => x.Value!.GetValue<string>())
                : [];
            var role = await profile;
            _targetRole = role.Get("profile").Text("target_role").NonEmpty() ?? role.Text("target_role").NonEmpty();
            _prices = (await prices).Items("items");
            _now = Beijing.Now;
            _loaded = true;
            _failed = false;
            if (!_applied)
            {
                _applied = true;
                if (_practice is { } practice)
                {
                    _type = practice.InterviewType;
                    _difficulty = practice.Difficulty ?? _difficulty;
                    _mode = practice.Mode ?? _mode;
                    if (practice.ResumeId is { } id) _resume = id;
                }
                if (!_speech) _mode = "text";
            }
            ApplyDefaults();
        }
        catch (OperationCanceledException) { return; }
        catch (Exception) { _failed = true; }
        Render();
    }

    /// <summary>岗位关联的简历优先，否则最近更新的一份。</summary>
    void ApplyDefaults()
    {
        if (_resumes.Count == 0) return;
        var linked = Target.Application.Display("resume_id");
        if (_practice?.ResumeId is null && linked.Length > 0 && _resumes.Any(x => x.Display("id") == linked)) { _resume = linked; return; }
        if (!_resumes.Any(x => x.Display("id") == _resume))
            _resume = _resumes.OrderByDescending(x => x.Text("updated_at"), StringComparer.Ordinal).First().Display("id");
    }

    JsonNode? PracticeFocusBody()
    {
        static string Free(string label) { var text = "free:" + label; return text.Length > 128 ? text[..128] : text; }
        if (_practice is { } practice && practice.Items.FirstOrDefault() is { } first)
            return new JsonObject
            {
                ["kind"] = "topic", ["ref"] = Free(first.Label), ["label"] = first.Label, ["origin"] = "settings", ["mode"] = "continue", ["question"] = first.Question,
                ["items"] = new JsonArray(practice.Items.Select(x => (JsonNode)new JsonObject
                {
                    ["label"] = x.Label, ["question"] = x.Question, ["signals"] = new JsonArray(x.Signals.Select(s => (JsonNode)JsonValue.Create(s)!).ToArray()),
                }).ToArray()),
            };
        if (ActivePlan == Plan.Full && _focus is null) return null;
        if (_focus is { } focus)
            return new JsonObject { ["kind"] = focus.Kind, ["ref"] = focus.Ref.Length == 0 ? Free(focus.Label) : focus.Ref, ["label"] = focus.Label, ["origin"] = "outline" };
        if (Stuck is not { } stuck || stuck.Text("topic").NonEmpty() is not { } label) return null;
        var fields = new JsonObject { ["kind"] = "topic", ["ref"] = stuck.Text("node").NonEmpty() ?? Free(label), ["label"] = label, ["origin"] = "settings" };
        if (stuck.Text("question").NonEmpty() is { } question) { fields["mode"] = "continue"; fields["question"] = question; }
        return fields;
    }

    async Task StartAsync()
    {
        if (!_loaded || _submitting) return;
        if (Blocking is { } blocking) { _open(blocking.Display("id")); return; }
        if (_resume.Length == 0) { MP.Notice("这场没有开始", "先导入或新建一份简历，面试官按简历出题。", true); return; }
        _submitting = true;
        Render();
        var body = new JsonObject
        {
            ["resume_id"] = _resume, ["interview_type"] = ActiveType, ["difficulty"] = _difficulty, ["question_count"] = Count,
            ["follow_up_enabled"] = _followUp, ["language"] = _language, ["answer_mode"] = _mode,
        };
        var target = Target;
        if (target.Kind != MockMap.TargetKind.General && target.Application.Display("id") is { Length: > 0 } id) body["job_application_id"] = id;
        if (target.Kind == MockMap.TargetKind.General && _targetRole is { } role) body["target_role"] = role;
        if (_mode == "voice")
        {
            body["interviewer_voice"] = _voice;
            if (_voiceIds.TryGetValue(_voice, out var voiceId)) body["interviewer_voice_id"] = voiceId;
        }
        if (PracticeFocusBody() is { } focus) body["practice_focus"] = focus;
        try
        {
            var result = await _life.Request("/api/mock-interviews", "POST", body);
            _open(result.Get("mock_interview").Display("id"));
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { MP.Notice("这场没有开始", MP.Error(error), true); }
        _submitting = false;
        Render();
    }
}

/// <summary>选择面试岗位（Windows 稿 09 · 02.02）：搜索 + 列表，没有 JD 的岗位去补；左下去投递看板添加。</summary>
internal sealed class MockJobDialog : UserControl
{
    readonly List<JsonNode> _jobs, _sessions;
    readonly DateTimeOffset _now;
    readonly Action _close;
    readonly Action<string?> _pick;
    readonly Action _showBoard, _showOpportunities;
    readonly V3SearchField _search = new("搜公司或岗位", "", height: 38);
    readonly StackPanel _list = new();
    string? _chosen;
    V3Button? _submit;

    MockJobDialog(List<JsonNode> jobs, List<JsonNode> sessions, DateTimeOffset now, string? current, Action close, Action<string?> pick, Action showBoard, Action showOpportunities)
    {
        (_jobs, _sessions, _now, _chosen, _close, _pick, _showBoard, _showOpportunities) = (jobs, sessions, now, current, close, pick, showBoard, showOpportunities);
        _search.Changed += _ => Fill();
        var scroll = V3.Scroll(_list);
        scroll.Height = 226;
        var body = VStack(10, _search.Top(16), scroll);
        _submit = MP.Dark(SubmitLabel(), () => { _close(); _pick(_chosen); }, 36);
        Content = MP.Form("选择面试岗位", "面试官按这个岗位的 JD 出题。", body, MP.Link("去投递看板添加 ›", () => { _close(); _showBoard(); }, blue: true),
            [MP.Ghost("取消", _close, 36), _submit]);
        Fill();
    }

    public static void Show(XamlRoot root, List<JsonNode> jobs, List<JsonNode> sessions, DateTimeOffset now, string? current, Action<string?> pick, Action showBoard, Action showOpportunities) =>
        V3Overlay.Show(root, close => new MockJobDialog(jobs, sessions, now, current, close, pick, showBoard, showOpportunities));

    string SubmitLabel() => _chosen is not null ? "用这个岗位练" : "不选岗位练";

    void Fill()
    {
        _list.Children.Clear();
        var keyword = _search.Text.Trim().ToLowerInvariant();
        if (keyword.Length == 0 || "不选岗位".Contains(keyword, StringComparison.Ordinal))
            _list.Children.Add(Row(_chosen is null, "不选岗位", "只按简历出题", null, () => { _chosen = null; Fill(); }));
        foreach (var item in _jobs.Where(x => keyword.Length == 0 || (x.Text("company_name_snapshot") + x.Text("job_title_snapshot")).ToLowerInvariant().Contains(keyword, StringComparison.Ordinal)))
        {
            var id = item.Display("id");
            var usable = item.Text("job_description_id").Length > 0 || item.Display("job_description_id").Length > 0;
            var session = _sessions.FirstOrDefault(s => s.Display("application_id") == id && (CareerApplication.Date(s.Text("end_at")) ?? DateTimeOffset.MinValue) >= _now);
            var sub = session is not null && CareerApplication.Date(session.Text("start_at")) is { } start
                ? $"{session.Text("stage_label")} · {MockMap.RelativeDay(start, _now)} {MockMap.Hhmm(start)}"
                : item.Text("current_stage_label");
            _list.Children.Add(Row(_chosen == id, $"{item.Text("company_name_snapshot")} · {item.Text("job_title_snapshot")}", sub,
                usable ? ("JD 已上传", false) : ("还没有 JD · 去补 ›", true),
                () => { if (usable) { _chosen = id; Fill(); } else { _close(); _showOpportunities(); } }));
        }
        if (_submit is not null) _submit.Title = SubmitLabel();
    }

    static FrameworkElement Row(bool on, string title, string sub, (string Text, bool Blue)? trailing, Action action)
    {
        var text = VStack(0, Label(title, 14, MP.Ink, Medium).Frame(height: 22), Sans(sub, 12.5, MP.Fnt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Frame(height: 18));
        var row = Columns(12, (Star(), text.Align(v: VerticalAlignment.Center)),
            (Auto, trailing is { } t ? Sans(t.Text, 12.5, t.Blue ? MP.Blue : MP.Mute).Align(v: VerticalAlignment.Center) : new Border()));
        var cell = new Border
        {
            Child = row, Height = 56, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(8),
            Background = Brush(on ? V3.White : Clear), BorderBrush = Brush(on ? MP.Ink : Clear), BorderThickness = new Thickness(1),
        };
        cell.OnTap(action, title);
        AutomationProperties.SetItemStatus(cell, on ? "已选" : "");
        return cell;
    }
}

/// <summary>更多设置（Windows 稿 09 · 02.05）：面试语言、面试官音色（语音作答时）、允许追问。</summary>
internal sealed class MockMoreDialog : UserControl
{
    public sealed record Value(string Language, bool FollowUp, Dictionary<string, string> VoiceIds);

    MockMoreDialog(string language, bool followUp, string voice, List<JsonNode> voices, Dictionary<string, string> voiceIds, Action close, Action<Value> save)
    {
        var lang = language;
        var follow = followUp;
        var ids = new Dictionary<string, string>(voiceIds);
        var options = voices.Where(x => x.Text("gender") == voice).ToList();
        var stack = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        var languageSeg = new V3Segmented<string>([("zh", "中文"), ("en", "英文")], lang, height: 30, fontSize: 12.5).Tip("面试语言");
        languageSeg.Changed += v => lang = v;
        stack.Children.Add(Option("面试语言", "面试官提问和报告使用的语言", languageSeg, false));
        if (options.Count > 0)
        {
            var picker = new ComboBox { Width = 140, FontFamily = SansFamily, FontSize = 13 };
            foreach (var option in options) picker.Items.Add(new ComboBoxItem { Content = option.Text("name"), Tag = option.Text("id") });
            picker.SelectedItem = picker.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == ids.GetValueOrDefault(voice));
            picker.SelectionChanged += (_, _) => { if (picker.SelectedItem is ComboBoxItem item) ids[voice] = (string)item.Tag; };
            AutomationProperties.SetName(picker, "面试官音色");
            stack.Children.Add(Option("面试官音色", $"这一场选的是{(voice == "male" ? "男声" : "女声")}", picker, true));
        }
        var toggle = new V3Switch(follow, "允许追问");
        toggle.Toggled += on => follow = on;
        stack.Children.Add(Option("允许追问", "每道主问题最多追问 2 次，关掉就一题一答", toggle, true));
        Content = MP.Form("更多设置", null, stack, null,
            [MP.Ghost("取消", close, 36), MP.Dark("保存", () => { close(); save(new Value(lang, follow, ids)); }, 36)]);
    }

    public static void Show(XamlRoot root, string language, bool followUp, string voice, List<JsonNode> voices, Dictionary<string, string> voiceIds, Action<Value> save) =>
        V3Overlay.Show(root, close => new MockMoreDialog(language, followUp, voice, voices, voiceIds, close, save));

    static FrameworkElement Option(string title, string sub, FrameworkElement control, bool line)
    {
        var row = Columns(24, (Star(), VStack(0, Label(title, 14, MP.Ink, Medium).Frame(height: 22), Sans(sub, 13, MP.Fnt).Frame(height: 20)).Align(v: VerticalAlignment.Center)),
            (Auto, control.Align(v: VerticalAlignment.Center)));
        return new Border { Child = row, MinHeight = 60, BorderBrush = Brush(MP.Line), BorderThickness = new Thickness(0, line ? 1 : 0, 0, 0) };
    }
}
