using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Home;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

// AI 对话（Windows 稿 02B 页）的分块视图，逻辑对齐 Mac `AssistantChatParts.swift`。主流程与接口调用在 AssistantChatView。

// MARK: 02B·02 新建对话：一行问句 + 输入框下的快捷输入

static class AssistantGreeting
{
    public sealed record Prompt(string Symbol, string Text);

    /// <summary>品牌山茶花（随包 mark.png）。</summary>
    public static Image Mark(double size) => new() { Width = size, Height = size, Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/mark.png")), Stretch = Stretch.Uniform };

    /// <summary>一行标语（Web `greetingTitle`）：备战时问“先准备哪块”，起步时讲第一步，其他沿用场景标题。</summary>
    public static string Title(HomeScene scene)
    {
        if (scene.Key == "start") return "先说说你做过什么，我来写第一版简历";
        if (scene.Key == "prep" && scene.Eyebrow.Length > 0) return Regex.Replace(scene.Eyebrow, "前$", "") + "，先准备哪块？";
        return scene.Title;
    }

    /// <summary>按状态给三条快捷输入（Web `greetingPrompts`）。</summary>
    public static List<Prompt> Prompts(HomeScene scene)
    {
        var first = scene.List.FirstOrDefault()?.Title;
        var second = scene.List.Count > 1 ? scene.List[1].Title : null;
        Prompt? ask = scene.Suggestion.Length == 0 ? null : new("questionmark.circle", scene.Suggestion);
        var review = new Prompt("clock.arrow.circlepath", "最近一次练习，帮我复盘一下");
        var @event = Regex.Replace(scene.Eyebrow, "前$", "");
        Prompt?[] candidates = scene.Key switch
        {
            "start" => [new("pencil", "我还没有简历，先跟你说说我做过什么"), new("square.and.arrow.up", "我有一份简历，帮我导入进来"), new("questionmark.circle", "第一份简历，该先写哪些内容")],
            "materials" => [scene.Suggestion.Length == 0 ? null : new("doc.text", scene.Suggestion), new("pencil", "按我上传的资料，写第一份简历"), new("questionmark.circle", "写简历之前，还缺哪些信息要补？")],
            "resume" => [first is null ? null : new("mic", $"模拟面试问问我「{first}」"), ask, new("doc.text", "我的简历里哪段经历最容易被追问？")],
            "experience" => [first is null ? null : new("mic", $"陪我练讲「{Regex.Replace(first, " · $", "")}」"), ask, new("doc.text", "我的简历里哪段经历最容易被追问？")],
            "prep" => [new("calendar", $"把{@event}可能问的问题列出来"), first is null ? null : new("mic", $"出三道「{first}」的题，我来答"), ask],
            "weak" => [first is null ? null : new("mic", $"出三道「{first}」的题，我来答"), first is null ? null : new("questionmark.circle", $"讲讲「{first}」，我再复述一遍"), ask],
            "return" => [ask is null ? null : new("mic", ask.Text), second is null ? null : new("questionmark.circle", $"「{second}」我上次答到哪了？"), review],
            _ => [ask, new("mic", "再陪我练一场，往深里问"), review],
        };
        var seen = new HashSet<string>();
        return candidates.OfType<Prompt>().Where(p => p.Text.Length > 0 && seen.Add(p.Text)).Take(3).ToList();
    }

    /// <summary>新建对话页的场景：与首页同一套规则（简历、资料、面试日程、记忆、求职意向）。</summary>
    public static async Task<HomeScene?> LoadSceneAsync()
    {
        var api = App.Session.Api;
        var now = DateTimeOffset.Now;
        static async Task<JsonNode?> Try(Task<JsonNode> task) { try { return await task; } catch { return null; } }
        var resumes = Try(api.CareerRequestAsync("/api/resumes"));
        var datasets = Try(api.CareerRequestAsync("/api/datasets"));
        var sessions = Try(api.CareerRequestAsync("/api/interview-sessions", query: new()
        {
            ["start_at"] = now.AddDays(-60).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["end_at"] = now.AddDays(30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
        }));
        var home = Try(api.CareerRequestAsync("/api/memory/home"));
        var profile = Try(api.CareerRequestAsync("/api/account/user-profile"));
        await Task.WhenAll(resumes, datasets, sessions, home, profile);
        if (resumes.Result is not { } list) return null;
        var input = new HomeInput(now, home.Result is { } h ? new MemoryHome(h) : null,
            list.Items("resumes").Select(ResumeSummary.From).OfType<ResumeSummary>().Select(r => new HomeResume(r.Id, r.Title, r.UpdatedAt)).ToList(),
            datasets.Result.Items("datasets").Select(x => new HomeDataset(x)).ToList(),
            sessions.Result.Items("items").Select(x => HomeSession.FromJson(x)).OfType<HomeSession>().ToList(),
            profile.Result.Items("job_directions").Select(x => x.String()).OfType<string>().ToList(),
            profile.Result.Text("target_role").NonEmpty());
        return HomeScenes.Pick(input);
    }

    /// <summary>标语行（02B·02）：30 号山茶花 + 26 号半粗问句。</summary>
    public static FrameworkElement TitleRow(string? text)
    {
        var row = HStack(12, Mark(30), Label(text ?? " ", 26, Txt, Bold).Wrap(2).Align(v: VerticalAlignment.Center));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        row.Height = 37;
        row.Opacity = text is null ? 0 : 1;
        return row;
    }

    /// <summary>快捷输入（02B·02 方案 A）：一列，每行 44 高，图标 + 一句话，行间细线；悬停 #F4F4F1 圆角 8。点一下只填进输入框。</summary>
    public static FrameworkElement PromptList(IReadOnlyList<Prompt> prompts, Action<string> pick)
    {
        var stack = new StackPanel();
        AutomationProperties.SetName(stack, "快捷输入");
        var lines = new List<Border>();
        for (var i = 0; i < prompts.Count; i++)
        {
            var prompt = prompts[i];
            if (i > 0)
            {
                var line = new Border { Height = 1, Background = Brush(Hex(0xECEBE6)), Margin = new Thickness(14, 0, 14, 0) };
                lines.Add(line);
                stack.Children.Add(line);
            }
            var index = i;
            var row = new Border
            {
                Height = 44, CornerRadius = new CornerRadius(8), Padding = new Thickness(17, 0, 17, 0), Background = Brush(Clear),
                Child = HStack(14, Icon(prompt.Symbol, 13, Sub).Frame(width: 15).Align(v: VerticalAlignment.Center),
                    Sans(prompt.Text, 14, Hex(0x3D3D3A)).Wrap(1).Align(v: VerticalAlignment.Center)),
            };
            row.OnHover(on =>
            {
                row.Background = Brush(on ? Hex(0xF4F4F1) : Clear);
                if (index > 0) lines[index - 1].Opacity = on ? 0 : 1;
                if (index < lines.Count) lines[index].Opacity = on ? 0 : 1;
            });
            stack.Children.Add(row.OnTap(() => pick(prompt.Text), prompt.Text));
        }
        return stack;
    }
}

// MARK: 02B·04 回复前的准备过程

/// <summary>一轮回复的准备过程（Web `ProcessSnapshot`）：文字过程与工具调用按出现顺序排列；最终正文开始后仍保留，折成回答上方一行。</summary>
sealed class ProcessSnapshot
{
    public abstract record Entry { public sealed record Text(string Value) : Entry; public sealed record Tool(string Key) : Entry; }
    public sealed record Activity(string CallKey, string Label, string Status, string Summary);
    public sealed record Step(string Id, bool Tool, string Title, string? Detail, string? Status, string? Symbol);

    public List<Entry> Timeline { get; } = [];
    public List<Activity> Activities { get; } = [];
    public DateTimeOffset Started { get; init; } = DateTimeOffset.Now;
    public DateTimeOffset? Ended { get; set; }

    public void Apply(Activity activity)
    {
        var index = Activities.FindIndex(a => a.CallKey == activity.CallKey);
        if (index >= 0) Activities[index] = activity;
        else { Activities.Add(activity); Timeline.Add(new Entry.Tool(activity.CallKey)); }
    }

    public void AppendText(string delta)
    {
        if (Timeline.LastOrDefault() is Entry.Text text) Timeline[^1] = new Entry.Text(text.Value + delta);
        else Timeline.Add(new Entry.Text(delta));
    }

    /// <summary>时间线 → 卡片行（Web `processSteps`）：工具按 callKey 原位更新；文字过程去掉与工具标签重复的行。</summary>
    public List<Step> Steps
    {
        get
        {
            var toolLabels = Activities.Select(a => Head(a.Label)).ToHashSet();
            var steps = new List<Step>();
            for (var index = 0; index < Timeline.Count; index++)
            {
                switch (Timeline[index])
                {
                    case Entry.Tool tool when Activities.FirstOrDefault(a => a.CallKey == tool.Key) is { } activity:
                    {
                        var label = Regex.Replace(activity.Label, "[…。.]+$", "");
                        var parts = label.Split('：');
                        var name = Regex.Replace(parts[0], "^正在", "");
                        var detail = activity.Status == "failed" ? "没有成功" : string.Join(" · ", new[] { string.Join("：", parts.Skip(1)), activity.Summary }.Where(x => x.Length > 0));
                        steps.Add(new Step(tool.Key, true, activity.Status == "running" ? $"正在{name}…" : name, detail.Length == 0 ? null : detail, activity.Status, Symbol(name)));
                        break;
                    }
                    case Entry.Text text:
                    {
                        var lines = text.Value.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0 && !toolLabels.Contains(Head(l))).ToList();
                        if (lines.Count > 0) steps.Add(new Step($"text:{index}", false, string.Join("\n", lines), null, null, null));
                        break;
                    }
                }
            }
            return steps;
        }
    }

    static string Head(string label) => label.Split('…', '：')[0];

    /// <summary>工具图标表（02B·04 Tool icons）。</summary>
    static string? Symbol(string name)
    {
        (string, string)[] table =
        [
            ("查看简历", "doc.text"), ("新建简历", "doc.badge.plus"), ("生成修改建议", "pencil"), ("修改任务", "pencil"), ("翻译简历", "character.bubble"),
            ("换模板", "rectangle.split.2x1"), ("查看模板", "square.grid.2x2"), ("生成待写入的简历内容", "square.and.pencil"), ("整理画像建议", "person"),
            ("查看资料库", "folder"), ("检索资料内容", "magnifyingglass"), ("保存附件到资料库", "folder.badge.plus"), ("查看附件", "paperclip"),
            ("查看岗位", "briefcase"), ("搜索岗位广场", "building.2"), ("加入我的岗位", "bookmark"), ("计算匹配度", "gauge.with.dots.needle.33percent"),
            ("查看投递", "paperplane"), ("更新投递进度", "flag"), ("查看日程", "calendar"), ("查看模拟面试", "mic"),
            ("查询求职记忆", "clock.arrow.circlepath"), ("读取写作规则", "book"), ("读取工作流", "book"), ("向用户确认", "questionmark.bubble"),
            ("打开功能页面", "arrow.up.forward.square"), ("查看会员方案", "crown"),
        ];
        return table.FirstOrDefault(x => name.StartsWith(x.Item1, StringComparison.Ordinal)).Item2;
    }
}

static class ProcessViews
{
    static readonly Color Quiet = Hex(0x8A8A84);

    /// <summary>工具卡（02B·04）：560 宽、白底 15% 墨线细边、圆角 8、轻阴影；一步一行 34 高，图标之间用细线串起来。默认只露最近两步。</summary>
    public static FrameworkElement Card(IReadOnlyList<ProcessSnapshot.Step> steps, bool expanded, Action? expand)
    {
        var shown = expanded ? steps.ToList() : steps.TakeLast(2).ToList();
        var hidden = steps.Count - shown.Count;
        var list = new StackPanel();
        for (var index = 0; index < shown.Count; index++)
        {
            var step = shown[index];
            var glyph = new Grid { Width = 20, Height = 20, Margin = new Thickness(0, 0, 10, 0) };
            if (index > 0) glyph.Children.Add(new Border { Width = 1, Height = 14, Background = Brush(Alpha(Hex(0x0B0B0B), 0.13)), VerticalAlignment = VerticalAlignment.Top, RenderTransform = new TranslateTransform { Y = -20 } });
            glyph.Children.Add(Glyph(step));
            var title = Sans(step.Title, 13.5, !step.Tool || step.Status == "running" ? Quiet : Txt).Wrap(step.Tool ? 1 : 3);
            var row = new StackPanel { Orientation = Orientation.Horizontal, MinHeight = 34 };
            row.Children.Add(glyph.Align(v: VerticalAlignment.Center));
            row.Children.Add(title.Align(v: VerticalAlignment.Center));
            if (step.Detail is { } detail) row.Children.Add(Sans(detail, 12.5, step.Status == "failed" ? Red : Hex(0xA3A39D)).Wrap(1).Pad(10, 0, 0, 0).Align(v: VerticalAlignment.Center));
            list.Children.Add(row);
        }
        var card = new Border
        {
            Child = list, Width = 560, Padding = new Thickness(19, 11, 19, 11), Background = Brush(White), CornerRadius = new CornerRadius(10),
            BorderBrush = Brush(Alpha(Hex(0x1F1E1D), 0.15)), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left,
        }.Elevate(4);
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(card);
        if (hidden > 0 && expand is not null) stack.Children.Add(Sans($"前面还有 {hidden} 步  ·  展开", 12.5, Quiet).OnTap(expand, "展开全部步骤"));
        return stack;
    }

    static FrameworkElement Glyph(ProcessSnapshot.Step step)
    {
        FrameworkElement dot = new Ellipse { Width = 5, Height = 5, Fill = Brush(Fnt2) };
        if (!step.Tool) return dot.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        if (step.Status == "running") return new Ellipse { Width = 11, Height = 11, Stroke = Brush(Orange), StrokeThickness = 1.4 }.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        if (step.Symbol is { } symbol) return Icon(symbol, 12, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        return dot.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
    }

    /// <summary>回复完成后（02B·04 · 01.1d'）：过程折成回答上方的一行「✓ 做了 N 步准备，用时 M 秒 ›」，点开是完整工具卡。</summary>
    public static FrameworkElement? Fold(ProcessSnapshot snapshot, bool open, Action toggle)
    {
        var steps = snapshot.Steps;
        var tools = steps.Count(s => s.Tool);
        if (tools == 0) return null;
        var seconds = snapshot.Ended is { } ended ? Math.Max(1, (int)Math.Round((ended - snapshot.Started).TotalSeconds)) : (int?)null;
        var chevron = Icon("chevron.right", 8, Quiet);
        chevron.RenderTransform = new RotateTransform { Angle = open ? 90 : 0, CenterX = 4, CenterY = 4 };
        var head = HStack(6, Icon("checkmark", 9, Quiet).Align(v: VerticalAlignment.Center),
            Sans(seconds is { } s ? $"做了 {tools} 步准备，用时 {s} 秒" : $"做了 {tools} 步准备", 13, Quiet), chevron.Align(v: VerticalAlignment.Center));
        head.OnTap(toggle, "准备过程");
        if (open) AutomationProperties.SetItemStatus(head, "已展开");
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(head);
        if (open) stack.Children.Add(Card(steps, true, null));
        return stack;
    }
}

/// <summary>等待回复（02B·03 / 04）：左侧 30 号山茶花轻轻呼吸，右侧当前一步与已用秒数，下面是工具卡。</summary>
sealed class AssistantThinking : UserControl
{
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly TextBlock _seconds = Number("0 秒", 12, Hex(0x8791A1), Regular);
    readonly DateTimeOffset _started;
    Image? _mark;

    public AssistantThinking(string phase, DateTimeOffset started, IReadOnlyList<ProcessSnapshot.Step> steps, bool expanded, Action<bool> setExpanded, bool compacting)
    {
        _started = started;
        Tick();
        _timer.Tick += (_, _) => Tick();
        Loaded += (_, _) => _timer.Start();
        Unloaded += (_, _) => _timer.Stop();
        AutomationProperties.SetName(this, $"AI 正在思考：{phase}");
        if (compacting)
        {
            Content = HStack(8, new ProgressRing { Width = 14, Height = 14, IsActive = true }, Sans(phase, 13.5, Hex(0x6E7582)).Align(v: VerticalAlignment.Center), _seconds.Align(v: VerticalAlignment.Center));
            return;
        }
        var head = HStack(8, Sans(phase, 15, Hex(0x6E7582)).Wrap(1).Align(v: VerticalAlignment.Center), _seconds.Align(v: VerticalAlignment.Center));
        head.Height = 24;
        if (expanded && steps.Count > 2) head.Children.Add(Sans("收起", 12.5, Hex(0x8A8A84)).Pad(4, 0, 0, 0).Align(v: VerticalAlignment.Center).OnTap(() => setExpanded(false), "收起步骤"));
        var stack = new StackPanel { Spacing = 12 };
        stack.Children.Add(head);
        if (steps.Count > 0) stack.Children.Add(ProcessViews.Card(steps, expanded, () => setExpanded(true)));
        _mark = AssistantGreeting.Mark(30);
        _mark.HorizontalAlignment = HorizontalAlignment.Left;
        _mark.VerticalAlignment = VerticalAlignment.Top;
        _mark.Margin = new Thickness(-54, -3, 0, 0);
        _mark.Opacity = 0.75;
        _mark.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromSeconds(1) };
        var grid = new Grid();
        grid.Children.Add(stack);
        grid.Children.Add(_mark);
        Content = grid;
    }

    void Tick()
    {
        var seconds = Math.Max(0, (int)(DateTimeOffset.Now - _started).TotalSeconds);
        _seconds.Text = $"{seconds} 秒";
        if (_mark is { } mark) mark.Opacity = seconds % 2 == 0 ? 0.75 : 1;
    }
}

// MARK: 02B·08 / 09 对话卡片

/// <summary>
/// 回复下面的卡片（Web `ActionCard`，02B·09 定稿）：白底细边、横排，按内容收宽、多张自动换行；点开的那张描黑边。
/// 回执卡与对象卡在右侧预览或跳到对应页面；跳转卡去功能页；确认卡在卡片内确认。
/// </summary>
static class AssistantActionCards
{
    public static readonly HashSet<string> ActionTypes = ["confirm", "receipt", "handoff", "objects", "jobs"];

    public static FrameworkElement Make(IReadOnlyList<JsonNode> cards, string? sessionId, int? sequenceNo, ChatPreviewTab? document, string? activeKey,
        Action<ChatPreviewTab> openPreview, Action<JsonNode> changed)
    {
        var flow = new VariableSizedFlow(8);
        foreach (var card in cards)
        {
            switch (card.Text("type"))
            {
                case "confirm": flow.Add(new AssistantConfirmCard(card, sessionId, sequenceNo, changed)); break;
                case "receipt": flow.Add(Receipt(card, activeKey, openPreview)); break;
                case "handoff": flow.Add(Handoff(card)); break;
                case "objects" or "jobs": foreach (var item in Objects(card)) flow.Add(ObjectCard(item)); break;
            }
        }
        if (document is not null)
            flow.Add(CardButton("doc.richtext", document.Label, $"AI 文档 · {document.Content.Length} 字", false, false, activeKey == document.Key, () => openPreview(document)));
        return flow.Panel;
    }

    static FrameworkElement Receipt(JsonNode card, string? activeKey, Action<ChatPreviewTab> openPreview)
    {
        var kind = card.Text("kind");
        var state = card.Text("status") == "processing" ? "解析中" : card.Text("status") == "failed" ? "解析失败" : "";
        var subtitle = string.Join(" · ", new[] { card.Text("subtitle"), state }.Where(x => x.Length > 0));
        ChatPreviewTab? tab = kind == "resume" ? new ChatPreviewTab(ChatPreviewTab.Kinds.Resume, card.Text("target_id"), card.Text("title"))
            : kind == "dataset" ? new ChatPreviewTab(ChatPreviewTab.Kinds.Dataset, card.Text("target_id"), card.Text("title")) : null;
        var symbol = kind switch { "resume" => "doc.text", "dataset" => "folder", "job" => "briefcase", _ => "doc" };
        return CardButton(symbol, card.Text("title"), subtitle, card.Text("status") == "failed", false, tab is not null && activeKey == tab.Key, () =>
        {
            if (tab is not null) openPreview(tab);
            else if (card.Text("application_id") is { Length: > 0 } application) WorkspaceShell.Current.OpenApplication(application);
            else WorkspaceShell.Current.Select(WorkspaceSection.Jobs);
        });
    }

    static FrameworkElement Handoff(JsonNode card)
    {
        var workflow = card.Text("workflow");
        var p = card["params"];
        var symbol = workflow switch
        {
            "mock_interview" => "mic", "resume_import" or "job_import" or "interview_record_import" => "square.and.arrow.up",
            "resume_guide" or "interview_review" => "doc.text", "section_refine" => "pencil", "interview_prep" => "target", _ => "arrow.right",
        };
        return CardButton(symbol, card.Text("title"), card.Text("subtitle"), false, true, false, () =>
        {
            var shell = WorkspaceShell.Current;
            switch (workflow)
            {
                case "mock_interview": shell.Select(WorkspaceSection.Mock); break;
                case "interview_review" or "interview_prep" or "interview_record_import":
                    if (p.Text("application_id") is { Length: > 0 } application) shell.OpenApplication(application); else shell.Select(WorkspaceSection.Jobs);
                    break;
                case "resume_guide" or "section_refine":
                    if (p.Text("resume_id") is { Length: > 0 } resume) shell.EditResume(resume); else shell.Select(WorkspaceSection.Resumes);
                    break;
                case "resume_import": shell.Select(WorkspaceSection.Resumes); break;
                case "job_import": shell.Select(WorkspaceSection.Jobs); break;
            }
        });
    }

    /// <summary>读工具找到的岗位、投递和模拟面试（旧消息里的岗位列表也按对象卡显示）。</summary>
    static IEnumerable<JsonNode> Objects(JsonNode card)
    {
        if (card.Text("type") == "objects") return card.Items("items");
        return card.Items("items").Select(item => (JsonNode)new JsonObject
        {
            ["kind"] = "pool_job", ["id"] = item.Text("id"), ["title"] = item.Text("title"), ["company"] = item.Text("company"),
            ["subtitle"] = string.Join(" · ", new[] { item.Text("company"), item.Text("city") }.Where(x => x.Length > 0)),
        });
    }

    /// <summary>对象卡（02B·09 · 02.10a）：左边公司首字方块或图标，右边标题 13.5 与一行说明 12。</summary>
    static FrameworkElement ObjectCard(JsonNode item)
    {
        var kind = item.Text("kind");
        var company = item.Text("company").NonEmpty() ?? item.Text("title");
        FrameworkElement lead = kind switch
        {
            "mock_interview" => Icon("mic", 15, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            "match" => Icon("gauge.with.dots.needle.33percent", 17, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            _ => new Border
            {
                Width = 31, Height = 31, CornerRadius = new CornerRadius(7.5), Background = Brush(White), BorderBrush = Brush(Hex(0xE3E3DF)), BorderThickness = new Thickness(1),
                Child = Label(company.Length > 0 ? company[..1] : "", 14, Hex(0x454842), Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            },
        };
        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Label(kind == "match" ? item.Text("subtitle").NonEmpty() ?? item.Text("title") : item.Text("title"), 13.5, Txt, Medium).Wrap(1));
        if (item.Text("subtitle").Length > 0 && kind != "match") texts.Children.Add(Sans(item.Text("subtitle"), 12, Hex(0x8A8A84)).Wrap(1));
        var border = new Border
        {
            Height = 53, Padding = new Thickness(11, 0, 14, 0), CornerRadius = new CornerRadius(9.5), Background = Brush(White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = HStack(11, new Grid { Width = 31, Height = 31, Children = { lead } }, texts),
        };
        Hover(border, () => false);
        return border.OnTap(() =>
        {
            var shell = WorkspaceShell.Current;
            switch (kind)
            {
                case "application": shell.OpenApplication(item.Text("id")); break;
                case "pool_job": shell.Select(WorkspaceSection.Opportunities); break;
                case "mock_interview": shell.Select(WorkspaceSection.Mock); break;
                default: shell.Select(WorkspaceSection.Jobs); break;
            }
        }, item.Text("title"));
    }

    public static FrameworkElement CardButton(string symbol, string title, string subtitle, bool failed, bool go, bool active, Action action)
    {
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Label(title, 14, Txt, Medium).Wrap(1).Frame(height: 20));
        if (subtitle.Length > 0) texts.Children.Add(Sans(subtitle, 12, failed ? Orange : Fnt).Wrap(1).Frame(height: 18));
        var row = HStack(12, Icon(symbol, 16, Sub).Frame(width: 32).Align(v: VerticalAlignment.Center), texts);
        if (go) row.Children.Add(Icon("arrow.right", 11, Fnt).Pad(4, 0, 0, 0).Align(v: VerticalAlignment.Center));
        var border = new Border
        {
            Child = row, Padding = new Thickness(12, 10, 16, 10), CornerRadius = new CornerRadius(10), Background = Brush(White),
            BorderBrush = Brush(active ? Txt : Cl), BorderThickness = new Thickness(1),
        };
        Hover(border, () => active);
        return border.OnTap(action, title);
    }

    /// <summary>卡片悬停只把描边加深（不加灰底色块）。</summary>
    static void Hover(Border border, Func<bool> active) => border.OnHover(on => border.BorderBrush = Brush(active() ? Txt : on ? Hex(0xC9C9C3) : Cl));
}

/// <summary>确认卡（02B·08 B）：右侧灰色「不用了」+ 白底细边「确认」；处理完换成一行状态；冲突时卡片下写红字。</summary>
sealed class AssistantConfirmCard : UserControl
{
    JsonNode _card;
    readonly string? _sessionId;
    readonly int? _sequenceNo;
    readonly Action<JsonNode> _changed;
    bool _busy;
    string? _error;

    public AssistantConfirmCard(JsonNode card, string? sessionId, int? sequenceNo, Action<JsonNode> changed)
    {
        _card = card; _sessionId = sessionId; _sequenceNo = sequenceNo; _changed = changed;
        Render();
    }

    void Render()
    {
        var status = _card.Text("status");
        var settled = status.Length > 0 && status != "pending";
        var ready = _sessionId is not null && (_sequenceNo ?? 0) > 0;
        var symbol = _card.Text("action") switch { "apply_template" => "rectangle.split.2x1", "application_add_stage" => "rectangle.3.group", "application_terminate" => "flag", _ => "pencil" };
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Label(_card.Text("title"), 14, settled ? Sub : Txt, Medium).Wrap(1).Frame(height: 20));
        if (_card.Text("subtitle").Length > 0) texts.Children.Add(Sans(_card.Text("subtitle"), 12, Fnt).Wrap(1).Frame(height: 18));
        UIElement right;
        if (settled)
        {
            var executed = status == "executed";
            var line = HStack(4, Sans(executed ? "已完成" : "已取消", 13, executed ? Green : Fnt));
            if (executed) line.Children.Insert(0, Icon("checkmark", 10, Green).Align(v: VerticalAlignment.Center));
            right = line;
        }
        else
        {
            var dismiss = Sans("不用了", 13, Sub).Align(v: VerticalAlignment.Center).OnTap(() => _ = ResolveAsync("dismissed"), "不用了", () => !_busy && ready);
            var confirm = new V3Button(_busy ? "处理中…" : "确认", () => _ = ConfirmAsync(), V3Button.Kind.Ghost, height: 28) { Enabled = !_busy && ready };
            right = HStack(12, dismiss, confirm);
        }
        var row = Columns(12, (new GridLength(32), Icon(symbol, 16, settled ? Faint : Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center)),
            (Star(), texts), (Auto, ((FrameworkElement)right).Align(v: VerticalAlignment.Center)));
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(row);
        if (_error is { } error) stack.Children.Add(Sans(error, 12, Red).Pad(44, 0, 0, 0));
        Content = new Border
        {
            Child = stack, MinWidth = 420, Padding = new Thickness(12, 10, 14, 10), CornerRadius = new CornerRadius(10), Background = Brush(White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
    }

    static JsonNode? Str(JsonNode? value) => value.Number() is { } number ? JsonValue.Create(number == Math.Round(number) ? ((long)number).ToString() : number.ToString(System.Globalization.CultureInfo.InvariantCulture))
        : value.String() is { } text ? JsonValue.Create(text) : null;
    static JsonNode? Num(JsonNode? value) => value.Number() is { } number ? JsonValue.Create(number)
        : double.TryParse(value.String(), System.Globalization.CultureInfo.InvariantCulture, out var parsed) ? JsonValue.Create(parsed) : null;

    /// <summary>卡片代表的产品操作，用用户自己的会话执行（Web `runConfirm`）。</summary>
    async Task RunAsync()
    {
        var p = _card["params"];
        var api = App.Session.Api;
        switch (_card.Text("action"))
        {
            case "apply_template":
                await api.CareerRequestAsync($"/api/resumes/{Str(p?["resume_id"]).String()}/apply-template", "POST",
                    body: new JsonObject { ["template_id"] = Str(p?["template_id"]), ["base_lock_version"] = Num(p?["base_lock_version"]) });
                break;
            case "application_add_stage":
                await api.CareerRequestAsync($"/api/job-applications/{Str(p?["application_id"]).String()}/stages", "POST", body: new JsonObject
                {
                    ["client_request_id"] = Str(p?["client_request_id"]), ["stage_type"] = Str(p?["stage_type"]), ["stage_label"] = Str(p?["stage_label"]),
                    ["interview_round_no"] = Num(p?["interview_round_no"]), ["base_lock_version"] = Num(p?["base_lock_version"]),
                });
                break;
            default:
                await api.CareerRequestAsync($"/api/job-applications/{Str(p?["application_id"]).String()}/terminate", "POST", body: new JsonObject
                {
                    ["client_request_id"] = Str(p?["client_request_id"]), ["reason"] = Str(p?["reason"]), ["base_lock_version"] = Num(p?["base_lock_version"]),
                });
                break;
        }
    }

    async Task ConfirmAsync()
    {
        _busy = true; _error = null; Render();
        try
        {
            await RunAsync();
            await ResolveAsync("executed", managed: false);
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = error is ApiException { Status: System.Net.HttpStatusCode.Conflict } ? "内容已经变了，这张卡片不能再用，请让助手重新生成。" : "这一步没有成功，请稍后再试。";
        }
        finally { _busy = false; Render(); }
    }

    async Task ResolveAsync(string status, bool managed = true)
    {
        if (_sessionId is null || _sequenceNo is not { } sequence) return;
        if (managed) { _busy = true; Render(); }
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/agent/sessions/{_sessionId}/messages/{sequence}/cards/{_card.Text("id")}:resolve", "POST",
                body: new JsonObject { ["status"] = status });
            if (result["card"] is JsonObject next) { _card = next; _changed(next); }
        }
        catch { _error = "这一步没有成功，请稍后再试。"; }
        finally { if (managed) _busy = false; Render(); }
    }
}

// MARK: 02B·11 修改建议直接写在回复里

/// <summary>
/// 修改建议（Web `SuggestionCard`，02B·11）：同一轮回复里的每一处列在一块容器里，标题栏写处数和进度；
/// 每处先给改后内容，「原文和原因」默认收起；采用、忽略、失败、过期都只换掉这一处右上角的按钮，不收起也不弹窗。
/// </summary>
sealed class AssistantSuggestionList : UserControl
{
    static readonly HashSet<string> Open = [];
    static readonly Color Mute = Hex(0x96968F), Done = Hex(0x2E8C57);
    readonly IReadOnlyList<JsonNode> _proposals;
    readonly string? _busy;
    readonly bool _running;
    readonly Func<JsonNode, Task<bool>> _apply, _reject;
    readonly Action<string> _rewrite;

    public AssistantSuggestionList(IReadOnlyList<JsonNode> proposals, string? busy, bool running, Func<JsonNode, Task<bool>> apply, Func<JsonNode, Task<bool>> reject, Action<string> rewrite)
    {
        _proposals = proposals; _busy = busy; _running = running; _apply = apply; _reject = reject; _rewrite = rewrite;
        AutomationProperties.SetName(this, "修改建议");
        Render();
    }

    public static string State(JsonNode proposal) => proposal.Text("superseded_by").Length > 0 ? "expired" : proposal.Text("status").NonEmpty() ?? "pending";

    static List<(string Before, string After, string Op, string Section, string Name)> Changes(JsonNode proposal)
    {
        var preview = proposal["preview"].Items("changes");
        if (preview.Count > 0) return preview.Select(c => (c.Text("before"), c.Text("after"), c.Text("op"), c.Text("section"), c.Text("name"))).ToList();
        var operations = proposal.Items("operations");
        if (operations.Count > 0)
            return operations.Select(o => (o["target"].Text("selected_text").NonEmpty() ?? "当前定位内容", o.Text("op") == "delete_target" ? "" : o.Text("new_text"), o.Text("op"), "", "")).ToList();
        return [("当前简历内容", "候选简历内容", "", "", "")];
    }

    string Progress()
    {
        int Count(string state) => _proposals.Count(p => State(p) == state);
        var pending = Count("pending");
        if (pending == _proposals.Count) return $"{pending} 处待确认";
        if (pending == 0 && Count("conflicted") == 0)
            return string.Join(" · ", new[] { "已处理" }.Concat(new[] { ("采用", Count("applied")), ("忽略", Count("rejected")), ("过期", Count("expired")) }.Where(x => x.Item2 > 0).Select(x => $"{x.Item1} {x.Item2}")));
        return string.Join(" · ", new[] { ("已采用", Count("applied")), ("已忽略", Count("rejected")), ("待确认", pending), ("没能采用", Count("conflicted")), ("已过期", Count("expired")) }
            .Where(x => x.Item2 > 0).Select(x => $"{x.Item1} {x.Item2}"));
    }

    void Render()
    {
        var multi = _proposals.Count > 1;
        var stack = new StackPanel();
        var head = HStack(8, Icon("pencil", 12, Sub).Align(v: VerticalAlignment.Center), Label(multi ? $"修改建议 · {_proposals.Count} 处" : "修改建议", 13, Txt, Medium));
        if (multi) head.Children.Add(Sans(Progress(), 13, Mute).Wrap(1));
        stack.Children.Add(new Border { Child = head.Align(v: VerticalAlignment.Center), MinHeight = 48, Padding = new Thickness(20, 0, 20, 0), Background = Brush(Hex(0xFAFAF9)) });
        for (var index = 0; index < _proposals.Count; index++)
        {
            stack.Children.Add(Divider());
            stack.Children.Add(Item(_proposals[index], index));
        }
        Content = new Border { Child = stack, Background = Brush(White), CornerRadius = new CornerRadius(12), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
    }

    FrameworkElement Item(JsonNode proposal, int index)
    {
        var state = State(proposal);
        var list = Changes(proposal);
        var place = string.Join(" · ", new[] { list.FirstOrDefault().Section ?? "", list.FirstOrDefault().Name ?? "" }.Where(x => x.Trim().Length > 0)).NonEmpty() ?? $"第 {index + 1} 处";
        var tags = proposal.Items("rationale").Select(r => r.Text("tag").Trim()).Where(t => t.Length > 0).Take(2);
        var dim = state is "rejected" or "expired";
        var id = proposal.Text("id");
        var expanded = Open.Contains(id);
        var locked = _busy is not null;
        var reason = proposal.Text("summary").Trim();

        var label = HStack(8, Label(place, 13, dim ? Mute : Sub, Medium).Wrap(1));
        foreach (var tag in tags)
            label.Children.Add(new Border { Child = Sans(tag, 12, Sub), Padding = new Thickness(7, 1, 7, 1), CornerRadius = new CornerRadius(4), Background = Brush(Field), Opacity = dim ? 0.6 : 1 });
        UIElement actions = state switch
        {
            "pending" => HStack(2, Sans("忽略", 13, Sub).Pad(8, 0, 8, 0).Align(v: VerticalAlignment.Center).OnTap(() => _ = _reject(proposal), "忽略", () => !locked),
                new V3Button(_busy == id ? "正在采用…" : "采用", () => _ = _apply(proposal), V3Button.Kind.Ghost, height: 26) { Enabled = !locked && !_running }),
            "conflicted" => HStack(2, Sans("忽略", 13, Sub).Pad(8, 0, 8, 0).Align(v: VerticalAlignment.Center).OnTap(() => _ = _reject(proposal), "忽略", () => !locked),
                new V3Button("按现在的内容重写", () => _rewrite(place), V3Button.Kind.Ghost, height: 26) { Enabled = !locked && !_running }),
            "applied" => Status("checkmark", "已采用", Done),
            "rejected" => Status("minus", "已忽略", Mute),
            _ => Status("clock", "已过期", Mute),
        };
        var stack = new StackPanel { Spacing = 8, Padding = new Thickness(20, 14, 20, 14) };
        var top = Columns(16, (Star(), label.Align(v: VerticalAlignment.Center)), (Auto, ((FrameworkElement)actions).Align(v: VerticalAlignment.Center)));
        top.MinHeight = 30;
        stack.Children.Add(top);
        var changes = new StackPanel { Spacing = 4 };
        foreach (var change in list)
        {
            var text = new TextBlock { FontFamily = SansFamily, FontSize = 14, LineHeight = 24, TextWrapping = TextWrapping.Wrap, Foreground = Brush(dim ? Mute : Txt), IsTextSelectionEnabled = true };
            if (change.Op is "delete_target" or "delete" || change.After.Length == 0) text.Text = $"删除这一条：{change.Before}";
            else foreach (var (piece, added) in Highlight(change.Before, change.After, dim)) text.Inlines.Add(new Run { Text = piece, FontWeight = added ? Medium : Regular });
            changes.Children.Add(text);
        }
        stack.Children.Add(changes);
        if (state == "conflicted")
            stack.Children.Add(HStack(6, Icon("exclamationmark.circle", 12, Red).Align(v: VerticalAlignment.Center), Sans("没能采用：简历里这一段刚被你改过，原文已经对不上。", 13, Red).Wrap()));
        if (state == "expired") stack.Children.Add(Sans("简历在这之后改过，这条建议不再适用。", 13, Mute).Wrap());
        else
        {
            stack.Children.Add(HStack(2, Sans(expanded ? "收起" : "原文和原因", 12, Mute), Icon(expanded ? "chevron.up" : "chevron.down", 8, Mute).Align(v: VerticalAlignment.Center))
                .OnTap(() => { if (!Open.Remove(id)) Open.Add(id); Render(); }, expanded ? "收起原文和原因" : "原文和原因"));
            if (expanded)
            {
                var detail = new StackPanel { Spacing = 4 };
                detail.Children.Add(Detail("原文", string.Join("\n", list.Select(c => c.Before).Where(x => x.Length > 0)).NonEmpty() ?? "（新增内容）", true));
                if (reason.Length > 0) detail.Children.Add(Detail("原因", reason, false));
                stack.Children.Add(detail);
            }
        }
        return stack;
    }

    static StackPanel Status(string symbol, string text, Color color) => HStack(4, Icon(symbol, 10, color).Align(v: VerticalAlignment.Center), Sans(text, 13, color)).Frame(height: 24);

    static FrameworkElement Detail(string label, string value, bool before)
    {
        var text = Sans(value, 13, before ? Mute : Sub).Wrap();
        text.LineHeight = 20;
        text.IsTextSelectionEnabled = true;
        return Columns(12, (new GridLength(24), Sans(label, 12, Mute)), (Star(), text));
    }

    /// <summary>改后内容里新增的关键信息加粗（Web `highlightAdded`）：按词对比原文，连续新增且不只是标点的片段加粗。</summary>
    public static List<(string Text, bool Added)> Highlight(string before, string after, bool dim)
    {
        static List<string> Tokens(string text) => Regex.Matches(text, @"[A-Za-z0-9.%+#]+|\s+|[^A-Za-z0-9.%+#\s]").Select(m => m.Value).ToList();
        var a = Tokens(before);
        var b = Tokens(after);
        if (dim || a.Count == 0 || b.Count == 0 || a.Count * b.Count > 250_000) return [(after, false)];
        var dp = new int[a.Count + 1, b.Count + 1];
        for (var i = a.Count - 1; i >= 0; i--)
            for (var j = b.Count - 1; j >= 0; j--)
                dp[i, j] = a[i] == b[j] ? dp[i + 1, j + 1] + 1 : Math.Max(dp[i + 1, j], dp[i, j + 1]);
        var parts = new List<(string Text, bool Added)>();
        void Push(string text, bool added)
        {
            if (parts.Count > 0 && parts[^1].Added == added) parts[^1] = (parts[^1].Text + text, added);
            else parts.Add((text, added));
        }
        int x = 0, y = 0;
        while (y < b.Count)
        {
            if (x < a.Count && a[x] == b[y]) { Push(b[y], false); x++; y++; }
            else if (x < a.Count && dp[x + 1, y] >= dp[x, y + 1]) x++;
            else { Push(b[y], true); y++; }
        }
        static bool Meaningful(string text) => text.Trim().Length >= 2 && text.Any(char.IsLetterOrDigit);
        var marked = parts.Select(p => (p.Text, p.Added && Meaningful(p.Text))).ToList();
        if (marked.All(p => p.Item2 || p.Text.Trim().Length == 0)) return [(after, false)];
        return marked;
    }
}

// MARK: 02B·07 添加资料（方案 B · 简化选择面板）

/// <summary>
/// 添加资料面板（02B·07 方案 B）：380 宽，贴在输入框上沿；搜索与分类都是纯文字，点一行就加进对话、再点取消，
/// 已加的行右侧打勾；上传放在最后一行，用细线和资料分开。输入 @ 时同一个面板按输入的字筛选。
/// </summary>
sealed class AssistantContextPanel : UserControl
{
    readonly Func<IReadOnlyList<JsonNode>> _groups;
    readonly Func<IReadOnlyList<JsonNode>> _chosen;
    readonly Func<string, string> _typeLabel;
    readonly Func<string?> _mention;
    readonly Action<JsonNode> _toggle;
    readonly Action _upload;
    string _query = "", _type = "";
    readonly StackPanel _list = new() { Padding = new Thickness(7, 0, 7, 0) };
    readonly StackPanel _types = new() { Orientation = Orientation.Horizontal, Spacing = 16, Margin = new Thickness(17, 12, 17, 10) };

    public AssistantContextPanel(Func<IReadOnlyList<JsonNode>> groups, Func<IReadOnlyList<JsonNode>> chosen, Func<string, string> typeLabel, Func<string?> mention, Action<JsonNode> toggle, Action upload)
    {
        _groups = groups; _chosen = chosen; _typeLabel = typeLabel; _mention = mention; _toggle = toggle; _upload = upload;
        Width = 380;
        AutomationProperties.SetName(this, "添加资料");
        var stack = new StackPanel();
        if (mention() is null)
        {
            var search = new TextBox { PlaceholderText = "搜索", FontSize = 14, BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0), MinHeight = 0 };
            Quiet(search.Resources);
            search.TextChanged += (_, _) => { _query = search.Text; Refresh(); };
            stack.Children.Add(Columns(10, (Auto, Icon("magnifyingglass", 11, Hex(0xA3A39C)).Align(v: VerticalAlignment.Center)), (Star(), search)).Pad(20, 14, 20, 0));
            stack.Children.Add(_types);
        }
        stack.Children.Add(new ScrollViewer { Content = _list, MaxHeight = 6 * 36 + 4, HorizontalScrollMode = ScrollMode.Disabled, Padding = new Thickness(0, mention() is null ? 0 : 7, 0, 0) });
        stack.Children.Add(new Border { Height = 1, Background = Brush(Hex(0xEDEDEA)), Margin = new Thickness(7, 4, 7, 0) });
        var upload2 = new Border
        {
            Height = 46, Padding = new Thickness(20, 0, 20, 0), Background = Brush(Clear),
            Child = HStack(10, Icon("square.and.arrow.up", 12, Sub).Align(v: VerticalAlignment.Center), Sans("上传本地文件", 14, Hex(0x33332F)).Align(v: VerticalAlignment.Center),
                Sans("图片、文档和录音", 12, Hex(0xA3A39C)).Align(v: VerticalAlignment.Center)),
        };
        stack.Children.Add(upload2.OnTap(upload, "上传本地文件"));
        Content = stack;
        Refresh();
    }

    static string Key(JsonNode item) => item.Text("type") + ":" + item.Text("id") + ":" + item.Text("version_id");
    bool Picked(JsonNode item) => _chosen().Any(c => Key(c) == Key(item));
    List<string> Types => _groups().Select(g => g.Text("type")).Where(t => t.Length > 0).ToList();
    string CurrentType => _type.Length > 0 ? _type : Types.FirstOrDefault() ?? "";
    string Search => (_mention() ?? _query).Trim();

    bool Matches(JsonNode item) => Search.Length == 0 || item.Text("label").Contains(Search, StringComparison.OrdinalIgnoreCase) || item.Text("description").Contains(Search, StringComparison.OrdinalIgnoreCase);
    List<JsonNode> Items(string type) => (_groups().FirstOrDefault(g => g.Text("type") == type)?.Items("items") ?? []).Where(Matches).ToList();

    /// <summary>每行一行小字（02B·07 B）：说明 + 浅灰日期。</summary>
    static string Hint(JsonNode item)
    {
        var parts = new List<string>();
        var description = item.Text("description");
        if (description.Length > 0 && description != "当前简历" && description.Length <= 16) parts.Add(description);
        if (ResumeSummary.ParseTimestamp(item.Text("updated_at")) is { } date) parts.Add(date.ToOffset(TimeSpan.FromHours(8)).ToString("MM-dd"));
        return string.Join(" · ", parts);
    }

    /// <summary>数据或筛选变了：重画分类和列表（外层在资料读回、@ 词变化时调用）。</summary>
    public void Refresh()
    {
        var mention = _mention();
        if (mention is null)
        {
            _types.Children.Clear();
            foreach (var value in Types)
            {
                var on = value == CurrentType;
                var count = _chosen().Count(c => c.Text("type") == value);
                var row = HStack(4, Label(_typeLabel(value), 13, on ? Hex(0x1F1F1D) : Hex(0x8A8A84), on ? Medium : Regular));
                if (count > 0 && !on)
                    row.Children.Add(new Border { MinWidth = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Brush(Txt), Child = Number(count.ToString(), 9.5, White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }.Align(v: VerticalAlignment.Center));
                var type = value;
                row.OnTap(() => { _type = type; Refresh(); }, _typeLabel(value));
                if (on) AutomationProperties.SetItemStatus(row, "已选择");
                _types.Children.Add(row);
            }
        }
        _list.Children.Clear();
        var list = mention is null ? Items(CurrentType) : Types.SelectMany(Items).ToList();
        if (list.Count == 0) _list.Children.Add(Empty(mention));
        foreach (var item in list) _list.Children.Add(Row(item, mention));
    }

    FrameworkElement Empty(string? mention)
    {
        if (_groups().Count == 0) return Sans("正在读取可引用的资料…", 13, Fnt).Pad(10, 9, 10, 9);
        var stack = new StackPanel { Spacing = 4, Padding = new Thickness(10, 9, 10, 9) };
        stack.Children.Add(Sans(Search.Length == 0 ? "这里还没有可引用的内容" : "没有匹配的资料", 13, Fnt));
        // 当前分类没有结果时，提示其他分类的命中数，点一下切过去
        if (mention is null && Search.Length > 0)
            foreach (var value in Types.Where(t => t != CurrentType))
                if (Items(value).Count is > 0 and var count)
                {
                    var type = value;
                    stack.Children.Add(Sans($"在「{_typeLabel(value)}」里找到 {count} 项", 12.5, Link).OnTap(() => { _type = type; Refresh(); }, _typeLabel(value)));
                }
        return stack;
    }

    FrameworkElement Row(JsonNode item, string? mention)
    {
        var added = Picked(item);
        var hint = mention is null ? Hint(item) : string.Join(" · ", new[] { _typeLabel(item.Text("type")), Hint(item) }.Where(x => x.Length > 0));
        var content = Columns(8,
            (Auto, Sans(item.Text("type") == "user_profile" ? "个人画像" : item.Text("label"), 14, Hex(0x1F1F1D)).Wrap(1).Also(t => t.MaxWidth = 220).Align(v: VerticalAlignment.Center)),
            (Star(), Sans(hint, 12, Hex(0xA3A39C)).Wrap(1).Align(v: VerticalAlignment.Center)),
            (Auto, added ? Icon("checkmark", 10, Hex(0x1F1F1D)).Align(v: VerticalAlignment.Center) : new Border()));
        var row = new Border { Child = content, Height = 36, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(6), Background = Brush(Clear) };
        row.OnHover(on => row.Background = Brush(on ? Field : Clear));
        if (added) AutomationProperties.SetItemStatus(row, "已添加");
        return row.OnTap(() => { _toggle(item); Refresh(); }, item.Text("label"));
    }
}

// MARK: 02B·12 / 13 上下文用量

static class AssistantUsage
{
    public const double Reserve = 16_384, MaxWindow = 200_000;
    static readonly (string Key, string Name, Color Color)[] Categories =
    [
        ("conversation", "对话记录", Blue), ("materials", "引用资料", Orange), ("memory", "求职记忆", Purple),
        ("attachments", "附件", Green), ("system", "系统指令与工具", Hex(0xA8A49A)),
    ];

    /// <summary>弹层里的数一律取整到 k（Web `formatTokens`）。</summary>
    public static string Format(double value) => value < 1000 ? ((int)value).ToString()
        : value < 1_000_000 ? $"{Math.Round(value / 1000)}k" : $"{value / 1_000_000:0.0}M";

    /// <summary>上下文用量弹层（02B·13，按 Claude 的写法列占比）：一行一类，最后一行是剩余空间；80% 以上右上角数字变橙。</summary>
    public static FrameworkElement Panel(JsonNode? usage, string? modelName, IReadOnlyDictionary<string, string> details, bool compactDisabled, Action compact)
    {
        var window = usage.Number("context_window") ?? 0;
        var limit = Math.Min(window, MaxWindow);
        var compactAt = Math.Max(1, limit - Reserve);
        var tokens = usage.Number("tokens");
        var stack = new StackPanel { Width = 340 - 38 };
        AutomationProperties.SetName(stack, "上下文用量");
        if (tokens is { } used)
        {
            var percent = Math.Min(100, used / compactAt * 100);
            var high = percent >= 80;
            var breakdown = usage?["breakdown"];
            var rows = Categories.Where(c => (breakdown.Number(c.Key) ?? 0) > 0).ToList();
            stack.Children.Add(Spread(Sans("上下文", 12.5, Txt), Number($"{Format(used)} / {Format(compactAt)}（{Math.Round(percent)}%）", 12.5, high ? Orange : Txt, Medium)));
            var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 1.5 };
            const double width = 302;
            if (breakdown is JsonObject)
                foreach (var (key, _, color) in rows) bar.Children.Add(new Border { Width = Math.Max(2, width * Math.Min(1, (breakdown.Number(key) ?? 0) / compactAt)), Background = Brush(color) });
            else bar.Children.Add(new Border { Width = width * Math.Min(1, used / compactAt), Background = Brush(Blue) });
            stack.Children.Add(new Border { Height = 6, CornerRadius = new CornerRadius(3), Background = Brush(Hex(0xEEEEEA)), Child = bar, Margin = new Thickness(0, 12, 0, 10) });
            foreach (var (key, name, color) in rows) stack.Children.Add(Line(color, name, details.GetValueOrDefault(key), breakdown.Number(key) ?? 0, compactAt, false));
            stack.Children.Add(Line(Hex(0xE4E4E0), "剩余空间", high ? "满了自动压缩" : null, Math.Max(0, compactAt - used), compactAt, true));
        }
        else
        {
            stack.Children.Add(Label("较早的对话已压缩成摘要", 13, Txt, Medium));
            stack.Children.Add(Sans("下次回复后重新计算用量；引用的资料、记忆和附件仍可随时读取。", 12, Sub).Wrap().Top(6));
        }
        stack.Children.Add(Divider().Top(10));
        var note = Sans(string.Join(" · ", new[] { modelName, $"用到 {Format(compactAt)} 时自动压缩" }.OfType<string>()), 11, Hex(0x8A8A84)).Wrap(1);
        UIElement button = new Border();
        if (tokens is not null)
        {
            var b = new Border { Height = 24, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(4), Background = Brush(Field), Opacity = compactDisabled ? 0.45 : 1, Child = Label("压缩上下文", 12, Txt, Medium).Align(v: VerticalAlignment.Center) };
            button = b.OnTap(compact, "压缩上下文", () => !compactDisabled);
        }
        stack.Children.Add(Columns(8, (Star(), note.Align(v: VerticalAlignment.Center)), (Auto, button)).Top(12));
        return stack;
    }

    static FrameworkElement Line(Color color, string name, string? detail, double value, double compactAt, bool muted)
    {
        var left = HStack(8, new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(1.5), Background = Brush(color) }.Align(v: VerticalAlignment.Center), Sans(name, 12.5, muted ? Hex(0x8A8A84) : Txt));
        if (detail is not null) left.Children.Add(Sans(detail, 11, Hex(0xA3A39C)).Wrap(1).Align(v: VerticalAlignment.Center));
        var row = Columns(8, (Star(), left.Align(v: VerticalAlignment.Center)),
            (new GridLength(40), Number(Format(value), 12, Hex(0x8A8A84), Regular).Also(t => t.TextAlignment = TextAlignment.Right).Align(v: VerticalAlignment.Center)),
            (new GridLength(52), Number($"{Math.Min(100, value / compactAt * 100):0.0}%", 12, muted ? Hex(0x8A8A84) : Txt, Medium).Also(t => t.TextAlignment = TextAlignment.Right).Align(v: VerticalAlignment.Center)));
        row.Height = 26;
        return row;
    }

    /// <summary>输入框底栏的上下文圆环（02B·12）：12 号细环，满格即自动压缩点，80% 以上变橙。</summary>
    public static FrameworkElement? Ring(JsonNode? usage, Action<FrameworkElement> toggle)
    {
        if (usage.Number("context_window") is not { } window) return null;
        var compactAt = Math.Max(1, Math.Min(window, MaxWindow) - Reserve);
        var percent = usage.Number("tokens") is { } tokens ? Math.Min(100, tokens / compactAt * 100) : (double?)null;
        var label = percent is { } p ? $"距自动压缩已用 {Math.Round(p)}%" : "上下文已压缩，下次回复后更新用量";
        var grid = new Grid { Width = 18, Height = 18, Background = Brush(Clear) };
        grid.Children.Add(new Ellipse { Width = 12, Height = 12, Stroke = Brush(Cl), StrokeThickness = 1.6 });
        if (percent is { } value and > 0)
        {
            var fraction = Math.Max(0.03, value / 100);
            const double radius = 5.2;
            var circumference = 2 * Math.PI * radius;
            var arc = new Ellipse
            {
                Width = 12, Height = 12, Stroke = Brush(value >= 80 ? Orange : Txt), StrokeThickness = 1.6, StrokeDashCap = PenLineCap.Round,
                StrokeDashArray = new DoubleCollection { fraction * circumference / 1.6, circumference / 1.6 },
                RenderTransform = new RotateTransform { Angle = -90, CenterX = 6, CenterY = 6 },
            };
            grid.Children.Add(arc);
        }
        grid.Tip(label);
        return grid.OnTap(() => toggle(grid), label);
    }
}
