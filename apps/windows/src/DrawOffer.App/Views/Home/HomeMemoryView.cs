using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Paper;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Home;
using DrawOffer.Core.Models;
using DrawOffer.Core.Resume;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Home;

/// <summary>
/// 工作区首页（Windows 稿 02A 页，逻辑对齐 Mac `HomeMemoryView` / Web `HomeMemory.tsx`）：
/// 没有简历 → 01 新用户（左边欢迎、右边一张能点能拖的简历纸）；有简历、第一份报告看完之前 → 03 / 06（练一场模拟面试）；
/// 有结论 → 07（最近进展 + 知识图谱 + 六个入口）。游客看到同一张新用户首页，点任何入口先登录。
/// </summary>
public sealed class HomeMemoryView : UserControl
{
    readonly Action? _guest;
    HomeGraph? _graph;
    HomeMockProgress? _mocks;
    bool _failed, _loaded, _disposed;
    int _request;
    readonly string _account = App.Session.User?.Id ?? "";

    HomeMemoryView(Action? guest)
    {
        _guest = guest;
        Background = Brush(White);
        Unloaded += (_, _) => _disposed = true;
        if (guest is not null) { Content = HomeCanvas.Make(new NewUserHome(null, null, guest)); return; }
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    public HomeMemoryView() : this(null) { }

    /// <summary>未登录时的首页：同一张新用户首页，点任何入口先登录。</summary>
    public static HomeMemoryView Guest(Action login) => new(login);

    string ReportSeenKey => $"home.firstReportSeen.{_account}";

    async Task LoadAsync()
    {
        var own = ++_request;
        _failed = false;
        var graph = Try(App.Session.Api.CareerRequestAsync("/api/memory/home/graph"));
        var mocks = Try(App.Session.Api.CareerRequestAsync("/api/mock-interviews"));
        var (g, m) = (await graph, await mocks);
        if (own != _request || _disposed) return;
        if (g is not null) _graph = new HomeGraph(g); else _failed = true;
        _mocks = m is null ? null : new HomeMockProgress(m);
        _loaded = true;
        Render();
        static async Task<JsonNode?> Try(Task<JsonNode> task) { try { return await task; } catch { return null; } }
    }

    void Render()
    {
        var shell = WorkspaceShell.Current;
        if (_failed && _graph is null)
        {
            Content = VStack(14, Label("首页信息暂时无法读取", 17, Txt, Medium), new V3Button("重试", () => _ = LoadAsync()).Align(HorizontalAlignment.Center))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            return;
        }
        if (_graph is not { } graph || !_loaded) { Content = new V3Loading("正在读取首页…"); return; }
        var seen = Resumes.EditorPreferences.Read(ReportSeenKey, "") == "1";
        var (screen, steps) = HomeStage.Pick(graph, _mocks, seen);
        Content = screen switch
        {
            HomeStage.Screen.NewUser => HomeCanvas.Make(new NewUserHome(() => _ = LoadAsync(), shell.EditResume, null)),
            HomeStage.Screen.FirstSteps => HomeCanvas.Make(new FirstStepsHome(graph, steps, _mocks?.FirstId, id =>
            {
                if (steps == HomeStage.FirstSteps.Report) Resumes.EditorPreferences.Write(ReportSeenKey, "1");
                if (id is not null) shell.OpenMockSession(id); else shell.Practice(null);
            }, () => shell.Select(WorkspaceSection.Opportunities), () => _ = LoadAsync())),
            HomeStage.Screen.ResumeOnly => HomeCanvas.Make(new FirstStepsHome(graph, HomeStage.FirstSteps.Start, null, _ => shell.Practice(null),
                () => shell.Select(WorkspaceSection.Opportunities), () => _ = LoadAsync())),
            _ => new FeedbackHome(graph),
        };
    }
}

/// <summary>1151×828 设计画布（Web DesignStage）：等比缩放、居中，最大放到 1.3 倍。</summary>
static class HomeCanvas
{
    public const double Width = 1151, Height = 828;

    public static FrameworkElement Make(FrameworkElement content)
    {
        content.Width = Width;
        content.Height = Height;
        return new Viewbox
        {
            Stretch = Stretch.Uniform, StretchDirection = StretchDirection.Both, Child = content,
            MaxWidth = Width * 1.3, MaxHeight = Height * 1.3, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// <summary>品牌花朵（随包 mark.png）。</summary>
    public static Image Mark(double size) => new() { Width = size, Height = size, Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/mark.png")), Stretch = Stretch.Uniform };

    /// <summary>首页里的文字链：15 号 sub，悬停转墨黑，末尾小箭头。</summary>
    public static StackPanel TextLink(string title, Action action, double size = 15)
    {
        var label = Sans(title, size, Sub);
        var chevron = Icon("chevron.right", size - 4, Sub);
        var link = HStack(4, label, chevron.Align(v: VerticalAlignment.Center));
        link.OnHover(h => { label.Foreground = Brush(h ? Txt : Sub); chevron.Foreground = Brush(h ? Txt : Sub); });
        return link.OnTap(action, title);
    }

    public static readonly Color Paper = Hex(0xFCFBF8), PaperEdge = Hex(0xE7E5DE), Hint = Hex(0xA5A39B);
}

// MARK: 01 新用户首页（Figma 02A·01 P1–P5）

sealed class NewUserHome : UserControl
{
    static readonly string[] Parts = ["基本信息", "教育经历", "实习经历", "项目经历", "技能"];
    enum Mode { Idle, Open, Drag }

    readonly Action? _reload, _guest;
    readonly Action<string>? _editResume;
    readonly Canvas _root = new() { Background = Brush(White) };
    Mode _mode = Mode.Idle;
    bool _hovering, _busy, _disposed;
    string? _readingId, _notice;
    int _read;

    public NewUserHome(Action? reload, Action<string>? editResume, Action? guest)
    {
        _reload = reload; _editResume = editResume; _guest = guest;
        Content = _root;
        _root.Tapped += (_, e) => { if (_mode == Mode.Open && e.OriginalSource == _root) { _mode = Mode.Idle; Render(); } };
        KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape && _mode == Mode.Open) { e.Handled = true; _mode = Mode.Idle; Render(); } };
        Loaded += async (_, _) => { if (_guest is null) await FindReadingAsync(); };
        Unloaded += (_, _) => _disposed = true;
        Render();
    }

    void Render()
    {
        _root.Children.Clear();
        _root.Children.Add(HStack(10, HomeCanvas.Mark(28), Label("欢迎来到职绘", 18, Txt, Medium).Align(v: VerticalAlignment.Center)).At(146, 210));
        _root.Children.Add(Label(_readingId is not null ? "正在读你的简历" : "从第一份简历开始", 52, Txt, Semibold).At(146, 258));
        var intro = Sans(_readingId is not null ? "读完以后，经历和技术都会记下来，\n可以先去别处看看，这里会自动更新。" : "职绘会记住你写过的经历、练过的题、面过的每一场，\n之后改简历、练面试、复盘，都接着这些往下帮你。", 17, Sub);
        intro.LineHeight = 30;
        intro.TextTrimming = TextTrimming.None;
        _root.Children.Add(intro.At(146, 346));
        if (_readingId is null)
        {
            var import = new V3Button("导入简历", () => { if (_guest is { } g) { g(); return; } OpenImport(null); }, V3Button.Kind.Dark, icon: null);
            var write = HomeCanvas.TextLink("没有现成的，写一份", WriteOne);
            _root.Children.Add(HStack(24, import, write.Align(v: VerticalAlignment.Center)).At(146, 446));
        }
        if (_notice is { } notice) _root.Children.Add(Sans(notice, 13, Sub).At(146, 520));
        _root.Children.Add(Stack().At(600, 100));
    }

    /// <summary>右边的纸：默认两张叠着略斜；悬停摆正抬起；点开变两个选项；拖文件变蓝色虚线；正在读按分区依次变深。</summary>
    UIElement Stack()
    {
        var flat = _mode != Mode.Idle || _hovering || _readingId is not null;
        var stack = new Canvas { Width = 460, Height = 600, Background = Brush(Clear), AllowDrop = true };
        if (!flat)
        {
            var under = new Border
            {
                Width = 360, Height = 480, CornerRadius = new CornerRadius(6), Background = Brush(Hex(0xF6F5F0)), BorderBrush = Brush(HomeCanvas.PaperEdge), BorderThickness = new Thickness(1),
                RenderTransform = new RotateTransform { Angle = -5 }, RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
            }.Elevate(6);
            stack.Children.Add(under.At(30.2, 33.4));
        }
        var drag = _mode == Mode.Drag;
        var paper = new Border
        {
            Width = 360, Height = 480, CornerRadius = new CornerRadius(6), Background = Brush(HomeCanvas.Paper), Child = Paper(),
            BorderBrush = Brush(drag ? Blue : HomeCanvas.PaperEdge), BorderThickness = new Thickness(drag ? 1.5 : 1),
            RenderTransform = new RotateTransform { Angle = flat ? 0 : 4 }, RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
        }.Elevate(flat ? 22 : 12);
        stack.Children.Add(paper.At(flat ? 40 : 62.8, flat ? (_readingId is not null ? 20 : 10) : 32));
        if (Hint() is { } hint)
        {
            var text = Sans(hint, 13, _readingId is not null ? Blue : HomeCanvas.Hint);
            text.Width = 360; text.TextAlignment = TextAlignment.Center;
            stack.Children.Add(text.At(40, flat ? 540 : 552));
        }
        stack.DragOver += (_, e) =>
        {
            if (_readingId is not null || !e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            e.DragUIOverride.IsGlyphVisible = false;
            e.DragUIOverride.Caption = "松手，开始读这份简历";
            if (_mode != Mode.Drag) { _mode = Mode.Drag; Render(); }
        };
        stack.DragLeave += (_, _) => { if (_mode == Mode.Drag) { _mode = Mode.Idle; Render(); } };
        stack.Drop += async (_, e) =>
        {
            _mode = Mode.Idle;
            Render();
            if (_guest is { } g) { g(); return; }
            if (_readingId is not null || !e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            if (items.FirstOrDefault() is Windows.Storage.StorageFile file) OpenImport(file.Path);
        };
        return stack;
    }

    string? Hint()
    {
        if (_readingId is not null) return $"正在读{Parts[_read]}…";
        return _mode switch
        {
            Mode.Open => "点纸外面收回",
            Mode.Drag => null,
            _ => _hovering ? "支持 PDF、Word、Markdown" : "点这张纸，或者把简历文件拖上来",
        };
    }

    UIElement Paper()
    {
        if (_readingId is not null) return PaperSkeleton.Make(_read);
        if (_mode == Mode.Drag)
            return VStack(14, Icon("square.and.arrow.up", 34, Blue).Align(HorizontalAlignment.Center), Label("松手，开始读这份简历", 17, Blue, Medium))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        if (_mode == Mode.Open)
        {
            var canvas = new Canvas { Width = 360, Height = 480, Background = Brush(HomeCanvas.Paper) };
            canvas.Children.Add(Label("放进你的简历", 20, Txt, Medium).At(35, 43));
            canvas.Children.Add(Sans("选一种开始，之后随时可以再换", 13, Fnt).At(35, 77));
            canvas.Children.Add(Option("square.and.arrow.up", "上传简历文件", "PDF、Word、Markdown 都可以", () => { _mode = Mode.Idle; Render(); OpenImport(null); }).At(19, 131));
            canvas.Children.Add(new Border { Width = 288, Height = 1, Background = Brush(HomeCanvas.PaperEdge) }.At(35, 245));
            canvas.Children.Add(Option("pencil", "从空白开始写", "没有现成的，跟着引导一段段写", () => { _mode = Mode.Idle; Render(); WriteOne(); }).At(19, 259));
            var foot = Sans("也可以直接把文件拖到这张纸上", 12, HomeCanvas.Hint);
            foot.Width = 360; foot.TextAlignment = TextAlignment.Center;
            canvas.Children.Add(foot.At(0, 431));
            return canvas;
        }
        var grid = new Grid { Background = Brush(HomeCanvas.Paper) };
        grid.Children.Add(PaperSkeleton.Make(-1));
        if (_hovering)
        {
            grid.Children.Add(new Border { Background = Brush(Alpha(White, 0.6)) });
            grid.Children.Add(Label("点一下，放进你的简历", 17, Txt, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        }
        grid.PointerEntered += (_, _) => { if (!_hovering) { _hovering = true; Render(); } };
        grid.PointerExited += (_, _) => { if (_hovering) { _hovering = false; Render(); } };
        return grid.OnTap(() => { if (_guest is { } g) { g(); return; } _mode = Mode.Open; _hovering = false; Render(); }, "放进你的简历");
    }

    static Border Option(string icon, string title, string sub, Action action)
    {
        var row = new Border
        {
            Width = 320, Height = 84, CornerRadius = new CornerRadius(8), Background = Brush(Clear), Padding = new Thickness(16, 0, 18, 0),
            Child = Columns(16, (new GridLength(24), Icon(icon, 20, Txt).Align(v: VerticalAlignment.Center)),
                (Star(), VStack(2, Label(title, 17, Txt, Medium), Sans(sub, 13, Fnt)).Align(v: VerticalAlignment.Center)),
                (Auto, Icon("chevron.right", 14, HomeCanvas.Hint).Align(v: VerticalAlignment.Center))),
        };
        row.OnHover(h => row.Background = Brush(h ? Hex(0xF4F3EE) : Clear));
        return row.OnTap(action, title);
    }

    void OpenImport(string? file)
    {
        if (XamlRoot is null) return;
        Resumes.ResumeImportSheet.Show(XamlRoot, _ => _ = FindReadingAsync(), file);
    }

    /// <summary>首页“写一份”：用默认模板新建（固定名字，重名加序号）并进编辑器引导。</summary>
    async void WriteOne()
    {
        if (_guest is { } g) { g(); return; }
        if (_busy) return;
        _busy = true; _notice = null; Render();
        try
        {
            foreach (var title in new[] { "我的第一份简历", "我的第一份简历 2", "我的第一份简历 3" })
            {
                try
                {
                    var result = await App.Session.Api.CareerRequestAsync("/api/resumes", "POST", body: new JsonObject { ["title"] = title, ["guide"] = true });
                    var id = (result["resume"] ?? result).Display("id");
                    if (id.Length > 0) _editResume?.Invoke(id);
                    return;
                }
                catch (ApiException error) when (error.Code == "RESUME_TITLE_CONFLICT") { }
                catch (ApiException error)
                {
                    _notice = error.Code switch
                    {
                        "RESUME_LIMIT_REACHED" => "简历数量已到上限，删掉一份再新建。",
                        "TEMPLATE_INACTIVE" => "暂时没有可用的模板，稍后再试。",
                        _ => "没能新建简历，请重试。",
                    };
                    return;
                }
                catch { _notice = "没能新建简历，请重试。"; return; }
            }
            _notice = "没能新建简历，请重试。";
        }
        finally
        {
            _busy = false;
            if (!_disposed) Render();
        }
    }

    /// <summary>刷新后也要知道还有一份在读：取导入列表里还没读完的一份。</summary>
    async Task FindReadingAsync()
    {
        JsonNode result;
        try { result = await App.Session.Api.CareerRequestAsync("/api/resumes"); } catch { return; }
        if (_disposed) return;
        var imports = result.Items("imports").Concat(result.Items("active_imports"));
        var active = imports.FirstOrDefault(item => item.Text("upload_status") != "failed" && item.Text("parse_status") is not ("failed" or "succeeded"));
        var previous = _readingId;
        _readingId = active?.Display("id") is { Length: > 0 } id ? id : null;
        if (_readingId is null && result.Items("resumes").Count > 0) { _reload?.Invoke(); return; }
        if (_readingId != previous) Render();
        if (_readingId is not null && previous is null) _ = PollReadingAsync();
    }

    /// <summary>P5 正在读：纸上每 2.4 秒亮一段；每 3 秒查一次，读完由首页重新取数换成有简历的首页。</summary>
    async Task PollReadingAsync()
    {
        _read = 0;
        var tick = 0;
        while (!_disposed && _readingId is not null)
        {
            await Task.Delay(600);
            tick++;
            if (tick % 4 == 0 && _read < Parts.Length - 1) { _read++; Render(); }
            if (tick % 5 == 0) await FindReadingAsync();
        }
    }
}

/// <summary>纸面骨架（Web `PaperSkeleton`，取自 02A·01 P2）；part：0 抬头 1 教育 2 实习 3 项目 4 技能，“正在读”按 part 依次变深。</summary>
static class PaperSkeleton
{
    enum Kind { Name, Role, Dot, Contact, Rule, Brand, Head, Unit, Date, Bullet, Line, Tag, Avatar }
    sealed record Bar(Kind Kind, double X, double Y, double W, double H, int Part);

    static IEnumerable<Bar> Entry(double y, double[] lines, int part)
    {
        yield return new(Kind.Unit, 31, y, 116, 6, part);
        yield return new(Kind.Date, 281, y, 46, 5, part);
        for (var i = 0; i < lines.Length; i++)
        {
            yield return new(Kind.Bullet, 33, y + 15 + i * 12, 3, 3, part);
            yield return new(Kind.Line, 42, y + 14 + i * 12, lines[i], 5, part);
        }
    }

    static readonly Bar[] Bars =
    [
        new(Kind.Name, 31, 33, 132, 15, 0), new(Kind.Role, 31, 57, 86, 8, 0), new(Kind.Avatar, 281, 29, 46, 46, 0),
        new(Kind.Dot, 31, 81, 6, 6, 0), new(Kind.Contact, 42, 81.5, 52, 5, 0),
        new(Kind.Dot, 113, 81, 6, 6, 0), new(Kind.Contact, 124, 81.5, 60, 5, 0),
        new(Kind.Dot, 195, 81, 6, 6, 0), new(Kind.Contact, 206, 81.5, 44, 5, 0),
        new(Kind.Rule, 31, 105, 296, 1, 0), new(Kind.Brand, 31, 104, 28, 3, 0),
        new(Kind.Head, 31, 125, 54, 7, 1),
        .. Entry(143, [176.7], 1), new(Kind.Head, 31, 185, 54, 7, 2), .. Entry(203, [262.2, 222.3, 156.75], 2),
        new(Kind.Head, 31, 269, 54, 7, 3), .. Entry(287, [250.8, 199.5], 3), .. Entry(331, [228], 3),
        new(Kind.Head, 31, 373, 40, 7, 4),
        new(Kind.Tag, 31, 391, 44, 15, 4), new(Kind.Tag, 82, 391, 58, 15, 4), new(Kind.Tag, 147, 391, 38, 15, 4), new(Kind.Tag, 192, 391, 52, 15, 4), new(Kind.Tag, 251, 391, 46, 15, 4),
    ];

    public static Canvas Make(int read)
    {
        var canvas = new Canvas { Width = 360, Height = 480, IsHitTestVisible = false };
        foreach (var bar in Bars)
        {
            var on = bar.Part <= read;
            FrameworkElement shape = bar.Kind switch
            {
                Kind.Avatar or Kind.Dot or Kind.Bullet => new Ellipse { Fill = Brush(ColorOf(bar.Kind, on)) },
                Kind.Tag => new Border { CornerRadius = new CornerRadius(8), Background = Brush(White), BorderBrush = Brush(on ? Hex(0xBDBBB3) : Hex(0xD6D4CC)), BorderThickness = new Thickness(1) },
                Kind.Rule => new Border { Background = Brush(ColorOf(bar.Kind, on)) },
                _ => new Border { CornerRadius = new CornerRadius(bar.Kind is Kind.Name or Kind.Role ? 4 : bar.Kind is Kind.Head or Kind.Brand ? 2 : 3), Background = Brush(ColorOf(bar.Kind, on)) },
            };
            shape.Width = bar.W;
            shape.Height = bar.H;
            canvas.Children.Add(shape.At(bar.X, bar.Y));
        }
        return canvas;
    }

    static Color ColorOf(Kind kind, bool on) => kind switch
    {
        Kind.Name => on ? Hex(0x2D2D2A) : Hex(0xCBC9C0),
        Kind.Role => on ? Hex(0x8F8D86) : Hex(0xDAD8D0),
        Kind.Avatar => on ? Hex(0xDCDAD3) : Hex(0xEBE9E3),
        Kind.Dot or Kind.Bullet => on ? Hex(0x8F8D86) : Hex(0xD3D1C9),
        Kind.Contact => on ? Hex(0xB3B1A9) : Hex(0xDDDBD4),
        Kind.Rule => Hex(0xE7E5DE),
        Kind.Brand => on ? Blue : Hex(0x9FB6EA),
        Kind.Head => on ? Hex(0x2D2D2A) : Hex(0xC2C0B7),
        Kind.Unit => on ? Hex(0x6F6E68) : Hex(0xD3D1C9),
        Kind.Date => on ? Hex(0xAEACA4) : Hex(0xE0DED7),
        Kind.Line => on ? Hex(0xCFCDC5) : Hex(0xE4E2DC),
        _ => White,
    };
}

// MARK: 03 / 06 第一份报告之前（Figma 02A·03 H3、02A·06 K2）

sealed class FirstStepsHome : UserControl
{
    readonly HomeGraph _graph;
    readonly HomeStage.FirstSteps _mode;
    readonly string? _mockId;
    readonly Action<string?> _open;
    readonly Action _jobs, _changed;
    JsonNode? _detail;
    bool _disposed;

    public FirstStepsHome(HomeGraph graph, HomeStage.FirstSteps mode, string? mockId, Action<string?> open, Action jobs, Action changed)
    {
        _graph = graph; _mode = mode; _mockId = mockId; _open = open; _jobs = jobs; _changed = changed;
        Loaded += async (_, _) => { await LoadDetailAsync(); if (_mode == HomeStage.FirstSteps.Evaluating) _ = PollEvaluatingAsync(); };
        Unloaded += (_, _) => _disposed = true;
        Render();
    }

    List<JsonNode> Rows => _detail?["report"].Items("questions").Where(x => !x.Bool("is_intro") && !x.Bool("skipped")).ToList() ?? [];

    (string Greet, string Title, string Intro, string Button, int Now) Copy()
    {
        var rows = Rows;
        var reached = rows.Count(x => x.Text("outcome") == "reached");
        return _mode switch
        {
            HomeStage.FirstSteps.Ongoing => ("第一场还没练完", "接着练完第一场", "回答都保存着，从上次停下的那题接着答。\n答完就出第一份报告。", "继续这一场", 1),
            HomeStage.FirstSteps.Evaluating => ("第一场练完了", "报告在整理", "面试官在把笔记整理成你的第一份报告，大约 1 分钟。\n好了这里会亮起来，等的时候可以先去看看岗位。", "整理中 · 约 1 分钟", 2),
            HomeStage.FirstSteps.Failed => ("第一场练完了", "报告没整理出来", "评估时出了点问题，你的回答都还在。\n点开这一场重新整理，再等一分钟就好。", "去重新整理", 2),
            HomeStage.FirstSteps.Report => ("第一份报告好了", "看看你答得怎么样",
                (_detail?["report"]?["total_score"].Number() is { } score ? $"{rows.Count} 题答到位 {reached} 题，{Math.Round(score)} 分。" : "分数和每道题的结论都出来了。") + "\n答得好和卡住的地方，都记进了你的长期记忆。",
                "看第一份报告", 2),
            _ => ("简历记下了", "练一场模拟面试", "题目按你简历里写的经历来出，大约 15 分钟。\n练完会记下你答得好和卡住的地方，出第一份报告。", "开始模拟面试", 1),
        };
    }

    void Render()
    {
        var copy = Copy();
        var root = new Canvas { Background = Brush(White) };
        root.Children.Add(Papers().At(560, 110));
        root.Children.Add(HStack(10, HomeCanvas.Mark(28), Label(copy.Greet, 16, Txt, Medium).Align(v: VerticalAlignment.Center)).At(146, 214));
        root.Children.Add(Label(copy.Title, 48, Txt, Semibold).At(146, 252));
        var intro = Sans(copy.Intro, 15, Sub);
        intro.LineHeight = 26; intro.TextTrimming = TextTrimming.None;
        root.Children.Add(intro.At(146, 340));
        var evaluating = _mode == HomeStage.FirstSteps.Evaluating;
        var start = new V3Button(copy.Button, () => _open(_mockId), V3Button.Kind.Dark, icon: null) { Enabled = !evaluating };
        var jobs = HStack(4, Sans("导入岗位", 15, Txt), Icon("chevron.right", 11, Fnt).Align(v: VerticalAlignment.Center)).OnTap(_jobs, "导入岗位");
        root.Children.Add(HStack(24, start, jobs.Align(v: VerticalAlignment.Center)).At(146, 420));
        root.Children.Add(Steps(copy.Now).At(146, 516));
        Content = root;
    }

    static UIElement Steps(int now)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        string[] labels = ["简历", "模拟面试", "第一份报告"];
        for (var i = 0; i < labels.Length; i++)
        {
            if (i > 0) row.Children.Add(new Border { Width = 24, Height = 1, Background = Brush(Hex(0xDCDAD2)), Margin = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center });
            UIElement mark = i < now ? Icon("checkmark", 9, Fnt)
                : i == now ? new Ellipse { Width = 7, Height = 7, Fill = Brush(Blue) }
                : new Ellipse { Width = 7, Height = 7, Stroke = Brush(Fnt2), StrokeThickness = 1.2 };
            row.Children.Add(HStack(6, ((FrameworkElement)mark).Align(v: VerticalAlignment.Center), Label(labels[i], 13, i == now ? Txt : Fnt, i == now ? Medium : Regular)));
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, "走到哪一步");
        return row;
    }

    UIElement Papers()
    {
        var canvas = new Canvas { Width = 560, Height = 600 };
        if (_graph.ResumeId is { } id)
        {
            var resume = new Border
            {
                Width = 340, Height = 481, CornerRadius = new CornerRadius(6), Background = Brush(White), BorderBrush = Brush(Hex(0xECEBE6)), BorderThickness = new Thickness(1),
                Child = new HomeResumePaper(id), RenderTransform = new RotateTransform { Angle = 6 },
            }.Elevate(18);
            canvas.Children.Add(resume.At(30, 40));
        }
        var report = _mode == HomeStage.FirstSteps.Report;
        var sheet = new Border
        {
            Width = 360, Height = 480, CornerRadius = new CornerRadius(6), Background = Brush(HomeCanvas.Paper), BorderBrush = Brush(Hex(0xECEBE6)), BorderThickness = new Thickness(1),
            Child = report ? ReportSheet() : InterviewSheet(), RenderTransform = new RotateTransform { Angle = -3 },
        }.Elevate(18);
        if (_mode != HomeStage.FirstSteps.Evaluating)
        {
            sheet.OnHover(h => sheet.Translation = new System.Numerics.Vector3(0, h ? -2 : 0, h ? 28 : 18));
            sheet.OnTap(() => _open(_mockId), report ? "看第一份报告" : "开始第一场");
        }
        canvas.Children.Add(sheet.At(170, 18));
        canvas.Children.Add(Sans(report ? "点这张纸，看报告" : _mode == HomeStage.FirstSteps.Evaluating ? "报告好了会出现在这里" : "点这张纸，开始第一场", 13, Fnt).At(290, 548));
        return canvas;
    }

    UIElement InterviewSheet()
    {
        var main = _detail.Items("questions").Where(x => x.Text("kind") == "main" && x.Text("content").Length > 0).ToList();
        var total = (int)(_detail?["question_count"].Number() ?? 3);
        var first = main.FirstOrDefault()?.Text("content") is { Length: > 0 } a ? a
            : _graph.Topics.FirstOrDefault() is { } t1 ? $"讲讲你在「{t1}」里做的事，为什么这样设计？" : "先做个自我介绍，再挑一段你最熟的经历讲讲。";
        var second = main.Skip(1).FirstOrDefault()?.Text("content") is { Length: > 0 } b ? b
            : _graph.Topics.Skip(1).FirstOrDefault() is { } t2 ? $"「{t2}」里最难的一处是怎么解决的？" : "这段经历里最难的一处是怎么解决的？";
        var answer = main.FirstOrDefault()?.Text("answer_text").Trim() ?? "";
        var answered = _mode != HomeStage.FirstSteps.Start && answer.Length > 0;
        var status = _mode switch
        {
            HomeStage.FirstSteps.Start => $"第一场 · {total} 题 · 约 15 分钟",
            HomeStage.FirstSteps.Ongoing => $"第一场 · 答到第 {Math.Max(1, (int)(_detail?["answered_main_questions"].Number() ?? 0) + 1)} 题",
            HomeStage.FirstSteps.Failed => "报告没整理出来 · 回答都还在",
            _ => "报告整理中，约 1 分钟",
        };
        var stack = new StackPanel { Width = 300, Spacing = 0 };
        stack.Children.Add(Sans("第 1 题 · 来自你的简历", 11, Fnt));
        var title = Label(first, 21, Txt, Semibold).Wrap();
        title.LineHeight = 30;
        stack.Children.Add(title.Top(10));
        stack.Children.Add(Wave(answered).Top(22));
        if (answered)
        {
            var text = new TextBlock { FontFamily = SansFamily, FontSize = 13, LineHeight = 22, TextWrapping = TextWrapping.Wrap };
            text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = answer.Length > 26 ? answer[..26] : answer, Foreground = Brush(Txt) });
            if (answer.Length > 26)
                text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = answer[26..Math.Min(answer.Length, 60)] + (answer.Length > 60 ? "……" : ""), Foreground = Brush(HomeCanvas.Hint) });
            stack.Children.Add(VStack(4, Sans("你答", 11, Fnt), text).Top(22));
        }
        else stack.Children.Add(Sans(_mode == HomeStage.FirstSteps.Start ? "轮到你时，直接开口说就行" : "还没答到这一题", 11.5, Fnt).Top(22));
        stack.Children.Add(new Border { Height = 1, Background = Brush(Hex(0xEFEEE9)), Margin = new Thickness(0, 22, 0, 0) });
        stack.Children.Add(Sans(_mode == HomeStage.FirstSteps.Start ? "第 2 题 · 来自你的简历" : "第 2 题", 11, HomeCanvas.Hint).Top(22));
        stack.Children.Add(Label(second, 15, Sub, Semibold).Wrap().Top(6));
        if (_mode == HomeStage.FirstSteps.Start) stack.Children.Add(Sans("第 3 题 · 开始后，接着你的回答追问", 11, HomeCanvas.Hint).Top(22));
        var canvas = new Canvas { Width = 360, Height = 480 };
        canvas.Children.Add(stack.At(30, 40));
        canvas.Children.Add(Fade().At(0, 310));
        canvas.Children.Add(Sans(status, 11.5, Fnt).At(30, 432));
        return canvas;
    }

    UIElement ReportSheet()
    {
        var report = _detail?["report"];
        var rows = Rows;
        var reached = rows.Count(x => x.Text("outcome") == "reached");
        var weak = rows.Count(x => x.Text("outcome") is "one_short" or "missed");
        var company = _detail is null ? "" : _detail.Text("company_name").Length == 0 ? _detail.Text("target_role")
            : string.Join(" · ", new[] { _detail.Text("company_name"), _detail.Text("job_title") }.Where(x => x.Length > 0));
        var stack = new StackPanel { Width = 300 };
        stack.Children.Add(HStack(14,
            Label(report?["total_score"].Number() is { } score ? Math.Round(score).ToString("0") : "—", 50, Txt, Semibold),
            VStack(2, Sans(string.Join(" · ", new[] { company, "第一场" }.Where(x => x.Length > 0)), 11, Fnt), Label($"{rows.Count} 题答到位 {reached} 题，{weak} 处要补", 13, Txt, Medium)).Align(v: VerticalAlignment.Center)));
        stack.Children.Add(new Border { Height = 1, Background = Brush(Hex(0xEFEEE9)), Margin = new Thickness(0, 22, 0, 0) });
        stack.Children.Add(Label("每道题", 15, Txt, Semibold).Top(22));
        var list = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var (row, index) in rows.Take(4).Select((x, i) => (x, i)))
        {
            if (index > 0) list.Children.Add(new Border { Height = 1, Background = Brush(Hex(0xEFEEE9)) });
            var outcome = row.Text("outcome") switch { "reached" => "答到位", "one_short" => "差一点", "missed" => "没答上", _ => "" };
            var note = row["highlights"].Items().FirstOrDefault().String() ?? row["weaknesses"].Items().FirstOrDefault().String() ?? "";
            list.Children.Add(Columns(12,
                (new GridLength(34), Label(Math.Round(row.Number("score") ?? 0).ToString("0"), 22, Txt, Semibold)),
                (Star(), VStack(1, Label(row.Text("topic"), 13, Txt, Medium), Sans(note, 11, Fnt)).Align(v: VerticalAlignment.Center)),
                (Auto, Label(outcome, 11.5, outcome == "答到位" ? Fnt : Hex(0xC9651B), outcome == "答到位" ? Regular : Medium).Align(v: VerticalAlignment.Center))).Pad(0, 10, 0, 10));
        }
        stack.Children.Add(list);
        var canvas = new Canvas { Width = 360, Height = 480 };
        canvas.Children.Add(stack.At(30, 40));
        canvas.Children.Add(Fade().At(0, 310));
        var foot = Spread(Sans(rows.Count > 4 ? $"还有 {rows.Count - 4} 题 · {weak} 处建议补" : $"{weak} 处建议补", 11.5, Fnt), Label("看完整报告 →", 12.5, Blue, Medium));
        foot.Width = 300;
        canvas.Children.Add(foot.At(30, 432));
        return canvas;
    }

    static Border Fade() => new()
    {
        Width = 360, Height = 170, IsHitTestVisible = false,
        Background = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(0, 1),
            GradientStops = { new GradientStop { Color = Alpha(HomeCanvas.Paper, 0), Offset = 0 }, new GradientStop { Color = HomeCanvas.Paper, Offset = 0.6 } },
        },
    };

    /// <summary>面试纸上的声波：56 根竖条，答过后变蓝。</summary>
    static UIElement Wave(bool live)
    {
        var grid = new Grid { Height = 28 };
        for (var i = 0; i < 56; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var envelope = Math.Sin(Math.PI * i / 55);
            var height = Math.Max(2, Math.Round(26 * envelope * (0.45 + 0.55 * Math.Abs(Math.Sin(i * 0.9 + 1.3) * Math.Cos(i * 0.7)))));
            var bar = new Border { Width = 2.2, Height = height, CornerRadius = new CornerRadius(1.1), Background = Brush(live ? Blue : Hex(0xCCC9C2)), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(bar, i);
            grid.Children.Add(bar);
        }
        return grid;
    }

    async Task LoadDetailAsync()
    {
        if (_mockId is null) return;
        try { _detail = (await App.Session.Api.CareerRequestAsync($"/api/mock-interviews/{Uri.EscapeDataString(_mockId)}"))["mock_interview"]; } catch { return; }
        if (!_disposed) Render();
    }

    /// <summary>报告整理中：每 4 秒查一次，好了首页原地换成“报告好了”。</summary>
    async Task PollEvaluatingAsync()
    {
        if (_mockId is null) return;
        while (!_disposed)
        {
            await Task.Delay(4000);
            if (_disposed) return;
            try
            {
                var value = (await App.Session.Api.CareerRequestAsync($"/api/mock-interviews/{Uri.EscapeDataString(_mockId)}"))["mock_interview"];
                if (value.Text("status") != "evaluating") { _changed(); return; }
            }
            catch { }
        }
    }
}

/// <summary>首页右边那页真实简历（与编辑器同一页的第一页）。</summary>
sealed class HomeResumePaper : UserControl
{
    public HomeResumePaper(string resumeId)
    {
        IsHitTestVisible = false;
        Background = Brush(White);
        Loaded += async (_, _) =>
        {
            try
            {
                var list = await App.Session.Api.CareerRequestAsync("/api/resumes");
                var summary = list.Items("resumes").Select(ResumeSummary.From).FirstOrDefault(x => x?.Id == resumeId);
                if (summary?.ToRenderRequest() is not { } request) return;
                var prepared = await App.Session.Api.PreparePaperAsync(request);
                var paper = new ResumePaperView { Width = 794, Height = 1123 };
                paper.Render(prepared.Request);
                Content = new Viewbox { Stretch = Stretch.UniformToFill, VerticalAlignment = VerticalAlignment.Top, Child = paper };
            }
            catch { }
        };
    }
}

// MARK: 07 有记忆（Figma 02A·07 S5，Web FeedbackHome）

sealed class FeedbackHome : UserControl
{
    readonly HomeGraph _graph;
    readonly Grid _root = new() { Background = Brush(White) };
    int _picked;
    bool _expanded;

    public FeedbackHome(HomeGraph graph)
    {
        _graph = graph;
        Content = _root;
        IsTabStop = true;
        KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape && _expanded) { e.Handled = true; _expanded = false; Render(); } };
        Render();
    }

    void Render()
    {
        _root.Children.Clear();
        if (_expanded) { _root.Children.Add(Expanded()); Focus(FocusState.Programmatic); return; }
        var head = HStack(22,
            new TextBlock
            {
                FontFamily = SansFamily, FontSize = 13, VerticalAlignment = VerticalAlignment.Center,
                Inlines =
                {
                    new Microsoft.UI.Xaml.Documents.Run { Text = "知识图谱", Foreground = Brush(Txt), FontWeight = Medium },
                    new Microsoft.UI.Xaml.Documents.Run { Text = "   " + (_graph.WeakPoints > 0 ? $"{_graph.Points} 个知识点，{_graph.WeakPoints} 个还不牢" : $"{_graph.Points} 个知识点"), Foreground = Brush(Fnt) },
                },
            },
            HStack(6, Label("展开", 13, Txt, Medium), Icon("arrow.up.left.and.arrow.down.right", 11, Txt).Align(v: VerticalAlignment.Center))
                .OnTap(() => { _expanded = true; Render(); }, "展开知识图谱")).Align(HorizontalAlignment.Right);
        var canvas = new HomeGraphCanvas(_graph.Nodes.Where(x => x.OnHome).ToList(), _graph.Edges, false) { MinHeight = 240 };
        canvas.DoubleTapped += (_, _) => { _expanded = true; Render(); };
        var graph = new Grid { RowSpacing = 4, RowDefinitions = { new RowDefinition { Height = Auto }, new RowDefinition { Height = Star() } } };
        graph.Children.Add(head);
        Grid.SetRow(canvas, 1);
        graph.Children.Add(canvas);

        var top = Columns(40, (Star(), Scroll(Timeline())), (Star(1.2), graph));
        var page = new Grid
        {
            MaxWidth = 1160, Padding = new Thickness(56, 48, 56, 43),
            RowDefinitions = { new RowDefinition { Height = Star() }, new RowDefinition { Height = Auto } },
        };
        page.Children.Add(top);
        var strips = Strips().Top(26);
        Grid.SetRow(strips, 1);
        page.Children.Add(strips);
        _root.Children.Add(page);
    }

    // 最近进展：选中的一条展开成大标题、说明和按钮，其余收成一行
    UIElement Timeline()
    {
        var list = new StackPanel();
        for (var index = 0; index < _graph.Timeline.Count; index++)
        {
            var item = _graph.Timeline[index];
            var text = HomeProgressText.Of(item, _graph.WeakPoints);
            var on = index == _picked;
            var rail = new Grid { Width = 10 };
            if (index < _graph.Timeline.Count - 1)
                rail.Children.Add(new Border { Width = 1, Background = Brush(Hex(0xD5D3C9)), Margin = new Thickness(0, on ? 17 : 31, 0, 0), HorizontalAlignment = HorizontalAlignment.Center });
            rail.Children.Add(new Ellipse
            {
                Width = on ? 10 : 9, Height = on ? 10 : 9, Fill = Brush(on ? Blue : White), Stroke = Brush(on ? Blue : Hex(0xBDBBB2)), StrokeThickness = 1,
                VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, on ? 5 : 20, 0, 0),
            });
            UIElement body;
            if (on) body = ExpandedItem(item, text);
            else
            {
                var picked = index;
                var when = Sans(HomeProgressText.When(item.Date, _graph.Today), 13, Fnt).Frame(width: 52);
                body = Columns(16, (Auto, when), (Star(), VStack(0, Sans(text.Short, 15, Txt).Wrap(1), Sans(item.Source, 12, Fnt))))
                    .Pad(0, 12, 0, 12).OnTap(() => { _picked = picked; Render(); }, text.Short);
            }
            list.Children.Add(Columns(16, (new GridLength(10), rail), (Star(), body)));
        }
        return list;
    }

    UIElement ExpandedItem(HomeGraph.Progress item, HomeProgressText.Text text)
    {
        var shell = WorkspaceShell.Current;
        var stack = new StackPanel();
        stack.Children.Add(Sans($"{HomeProgressText.When(item.Date, _graph.Today)}  ·  {item.Source}", 13, Fnt).Pad(0, 0, 0, 14));
        var title = new TextBlock { FontFamily = SansFamily, FontSize = 40, FontWeight = Semibold, LineHeight = 58, Foreground = Brush(Txt), TextWrapping = TextWrapping.Wrap };
        for (var i = 0; i < text.Lines.Count; i++)
        {
            var (before, mark, after) = text.Lines[i];
            if (i > 0) title.Inlines.Add(new Microsoft.UI.Xaml.Documents.LineBreak());
            title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = before });
            if (mark.Length > 0) title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = mark, Foreground = Brush(text.Weak ? Orange : Blue) });
            title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = after });
        }
        stack.Children.Add(new Viewbox { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left, Child = title });
        var desc = Sans(text.Desc, 16, Sub).Wrap();
        desc.LineHeight = 28; desc.MaxWidth = 544;
        stack.Children.Add(desc.Pad(0, 14, 0, 22));

        V3Button pill;
        if (item.Kind == HomeGraph.Source.Resume && _graph.ResumeId is { } id)
            pill = Pill("打开简历", () => shell.EditResume(id));
        else if ((item.PracticeLabel ?? _graph.Weakest?.Name) is { } label)
        {
            var focus = item.PracticeRef is { } reference ? new PracticeFocus(item.PracticeKind ?? "topic", reference, label)
                : _graph.Weakest is { } weakest ? new PracticeFocus("topic", weakest.Key, weakest.Name) : null;
            pill = Pill($"练{label.Split('（')[0]}", () => shell.Practice(focus));
        }
        else pill = Pill("再练一场", () => shell.Practice(null));
        var row = HStack(22, pill);
        if (item.Kind == HomeGraph.Source.Mock)
            row.Children.Add(HomeCanvas.TextLink("看这一场的报告", () => shell.OpenMockSession(item.SourceId), 14).Align(v: VerticalAlignment.Center));
        stack.Children.Add(row.Pad(0, 0, 0, 18));
        return stack;
    }

    static V3Button Pill(string title, Action action) => new(title, action, V3Button.Kind.Dark, height: 38, icon: "arrow.right");

    // 底部六个入口：三列两行
    UIElement Strips()
    {
        var shell = WorkspaceShell.Current;
        var entries = _graph.Entry;
        var overstated = _graph.Nodes.Where(x => x.Overstated).ToList();
        var interview = entries?.InterviewStart is { } start && HomeStage.ParseDate(start) is { } date
            ? $"{date.ToOffset(TimeSpan.FromHours(8)):M/d} {entries.InterviewCompany ?? ""}{entries.InterviewStage ?? "面试"}" + (entries.InterviewCount > 1 ? $"，共 {entries.InterviewCount} 场" : "")
            : "还没有排面试";
        var mock = entries is { MockCount: > 0 } ? $"练过 {entries.MockCount} 场" + (entries.MockLastScore is { } score ? $"，上一场 {Math.Round(score)} 分" : "") : "开始第一场";
        var saved = entries is null ? "还没有收藏岗位"
            : (entries.ApplicationsOpen > 0 ? $"{entries.ApplicationsOpen} 个在进行" : entries.JobsSaved > 0 ? $"{entries.JobsSaved} 个岗位" : "还没有收藏岗位")
              + (entries.ApplicationsAwaiting > 0 ? $"，{entries.ApplicationsAwaiting} 个等结果" : "");
        var resume = new TextBlock { FontFamily = SansFamily, FontSize = 15, FontWeight = Medium, Foreground = Brush(Txt), TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
        if (overstated.Count == 0) resume.Text = _graph.ResumeTitle;
        else
        {
            resume.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"{overstated.Count} 处写高了，" });
            resume.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = overstated[0].Label, Foreground = Brush(Hex(0xB5651A)) });
        }
        (string Icon, string Title, TextBlock Value, Action Go)[] items =
        [
            ("calendar", "面试日程", Value(interview), () => shell.Select(WorkspaceSection.Schedule)),
            ("mic", "模拟面试", Value(mock), () => shell.Select(WorkspaceSection.Mock)),
            ("doc.text", "我的简历", resume, () => { if (_graph.ResumeId is { } id) shell.EditResume(id); else shell.Select(WorkspaceSection.Resumes); }),
            ("briefcase", "推荐岗位", Value("按你的简历挑岗位"), () => shell.Select(WorkspaceSection.Opportunities)),
            ("square.split.1x2", "收藏的岗位", Value(saved), () => shell.Select(WorkspaceSection.Jobs)),
            ("folder", "资料库", Value(entries is { Datasets: > 0 } ? $"{entries.Datasets} 份资料" : "还没有资料"), () => shell.Select(WorkspaceSection.Datasets)),
        ];
        var grid = new Grid { ColumnSpacing = 44, RowSpacing = 18 };
        for (var c = 0; c < 3; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        for (var i = 0; i < items.Length; i++)
        {
            var item = items[i];
            var strip = Columns(12,
                (new GridLength(26), Icon(item.Icon, 19, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center)),
                (Star(), VStack(2, Sans(item.Title, 13, Fnt),
                    Columns(2, (Auto, item.Value), (Auto, Icon("chevron.right", 11, HomeCanvas.Hint).Align(v: VerticalAlignment.Center)), (Star(), new Border())))))
                .Pad(0, 4, 0, 4).OnTap(item.Go, item.Title);
            Grid.SetRow(strip, i / 3);
            Grid.SetColumn(strip, i % 3);
            grid.Children.Add(strip);
        }
        return grid;

        static TextBlock Value(string text) => Label(text, 15, Txt, Medium).Also(x => { x.TextTrimming = TextTrimming.CharacterEllipsis; x.MaxLines = 1; });
    }

    // 展开：原地铺满整页，全画；右上「收起」，左上标题与来源，左下图例
    UIElement Expanded()
    {
        var root = new Grid { Background = Brush(White) };
        root.Children.Add(new HomeGraphCanvas(_graph.Nodes, _graph.Edges, true) { Margin = new Thickness(48, 84, 48, 56) });
        var (resumes, mocks, interviews) = _graph.Sources;
        root.Children.Add(VStack(4, Label("你的知识图谱", 17, Txt, Semibold),
            Sans($"{_graph.Points} 个知识点 · 来自 {resumes} 份简历、{mocks} 场练习、{interviews} 场面试", 12.5, Fnt))
            .Align(HorizontalAlignment.Left, VerticalAlignment.Top).Pad(48, 28, 0, 0));
        root.Children.Add(HStack(18, Legend(Orange, "还不牢"), Legend(Blue, "刚练稳"), HStack(6, Sans("“ ”", 12, Sub), Sans("简历亮点", 12, Fnt)))
            .Align(HorizontalAlignment.Left, VerticalAlignment.Bottom).Pad(48, 0, 0, 24));
        root.Children.Add(HStack(6, Label("收起", 13, Txt, Medium), Icon("arrow.down.right.and.arrow.up.left", 11, Txt).Align(v: VerticalAlignment.Center))
            .OnTap(() => { _expanded = false; Render(); }, "收起知识图谱")
            .Align(HorizontalAlignment.Right, VerticalAlignment.Top).Pad(0, 32, 48, 0));
        return root;

        static StackPanel Legend(Color color, string text) =>
            HStack(6, new Ellipse { Width = 7, Height = 7, Fill = Brush(color), VerticalAlignment = VerticalAlignment.Center }, Sans(text, 12, Fnt));
    }
}

/// <summary>知识图谱画布：文字节点 + 细线；经历粗体，技术中号，知识点小号灰色，还不牢橙色、刚练稳蓝色。悬停高亮相连的线。</summary>
sealed class HomeGraphCanvas : UserControl
{
    readonly IReadOnlyList<HomeGraph.Node> _nodes;
    readonly IReadOnlyList<HomeGraph.Edge> _edges;
    readonly bool _large;
    readonly Canvas _canvas = new() { Background = Brush(Clear) };
    Dictionary<string, (double X, double Y)> _layout = [];
    readonly List<(HomeGraph.Edge Edge, Microsoft.UI.Xaml.Shapes.Line Line)> _lines = [];
    string? _hover;

    public HomeGraphCanvas(IReadOnlyList<HomeGraph.Node> nodes, IReadOnlyList<HomeGraph.Edge> edges, bool large)
    {
        _nodes = nodes; _edges = edges; _large = large;
        Content = _canvas;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, $"知识图谱，{nodes.Count} 个节点");
        SizeChanged += (_, _) => Draw();
        Loaded += async (_, _) =>
        {
            _layout = await Task.Run(() => HomeGraphLayout.Layout(_nodes, _edges));
            Draw();
        };
    }

    void Draw()
    {
        _canvas.Children.Clear();
        _lines.Clear();
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0 || _layout.Count == 0) return;
        (double X, double Y)? Point(string id) => _layout.TryGetValue(id, out var p) ? (p.X * w, p.Y * h) : null;
        foreach (var edge in _edges)
        {
            if (edge.Kind == "EE" || Point(edge.Src) is not { } a || Point(edge.Dst) is not { } b) continue;
            var line = new Microsoft.UI.Xaml.Shapes.Line { X1 = a.X, Y1 = a.Y, X2 = b.X, Y2 = b.Y, Stroke = Brush(Hex(0xE2E0D8)), StrokeThickness = 1, IsHitTestVisible = false };
            if (edge.Kind == "PP") line.StrokeDashArray = new DoubleCollection { 3, 4 };
            _lines.Add((edge, line));
            _canvas.Children.Add(line);
        }
        foreach (var node in _nodes)
        {
            if (Point(node.Id) is not { } at) continue;
            var (size, weight) = node.Kind switch
            {
                HomeGraph.Kind.Experience => (_large ? 23.0 : 15.0, Semibold),
                HomeGraph.Kind.Technology or HomeGraph.Kind.Session => (_large ? 19.0 : 13.0, Medium),
                HomeGraph.Kind.Highlight => (_large ? 14.0 : 12.0, Regular),
                _ => (_large ? 14.0 : 12.0, node.Tone == HomeGraph.Tone.Plain ? Regular : Medium),
            };
            var label = new Border
            {
                Padding = new Thickness(6, 5, 6, 5), CornerRadius = new CornerRadius(4), Background = Brush(Alpha(White, 0.85)),
                Child = Label(node.Short, size, ColorOf(node), weight),
            }.Tip(node.Label);
            var id = node.Id;
            label.OnHover(on => { var next = on ? id : _hover == id ? null : _hover; if (next != _hover) { _hover = next; Light(); } });
            label.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, at.X - label.DesiredSize.Width / 2);
            Canvas.SetTop(label, at.Y - label.DesiredSize.Height / 2);
            _canvas.Children.Add(label);
        }
    }

    /// <summary>悬停只换相连线的颜色，不重排节点。</summary>
    void Light()
    {
        foreach (var (edge, line) in _lines)
            line.Stroke = Brush(_hover is not null && (edge.Src == _hover || edge.Dst == _hover) ? Hex(0xA5A39B) : Hex(0xE2E0D8));
    }

    static Color ColorOf(HomeGraph.Node node) => node.Tone switch
    {
        HomeGraph.Tone.Hot => Orange,
        HomeGraph.Tone.New => Blue,
        _ => node.Kind switch
        {
            HomeGraph.Kind.Highlight => Sub,
            HomeGraph.Kind.Point => Hex(0x87867F),
            _ => Txt,
        },
    };
}
