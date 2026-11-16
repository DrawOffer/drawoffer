using DrawOffer.Core.Models;
using System.Text.Json.Nodes;
using System.ComponentModel;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 模拟面试重做（Windows 稿 09 · 模拟面试）的公共部件：配色、文字链、确认卡、表单卡、声纹、摘要四列。
/// 对应 Mac `MockKit.swift`、Web `v2/mi3.css`、`mi3Ui.tsx`、`Voiceprint.tsx`。按钮直接用 V3Button 胶囊（一页一个黑色）。
/// </summary>
internal static class MP
{
    public static readonly Color Ink = Hex(0x1D1D1B), Sub = Hex(0x55554F), Fnt = Hex(0x6C6C65), Mute = Hex(0x96968F), Hint = Hex(0x87867F),
        Faint = Hex(0xCFCFCA), Cl = Hex(0xE4E4E0), Line = Hex(0xECECEA), Edge = Hex(0xDEDEDA), Field = Hex(0xF7F7F4), Chip = Hex(0xF4F4F2),
        Hover = Hex(0xF3F3F0), RowHover = Hex(0xFAFAF8), Blue = Hex(0x3F6FD8), BlueDeep = Hex(0x2F5CC2), LightBlue = Hex(0x8AA9EE), Orange = Hex(0xD9822B);

    /// <summary>`.mi3-link`：灰字，悬停变墨黑；blue 时蓝字悬停加深。</summary>
    public static TextBlock Link(string title, Action action, double size = 13, bool blue = false, Color? color = null, Func<bool>? enabled = null)
    {
        var tint = color ?? (blue ? Blue : Fnt);
        var text = Sans(title, size, tint);
        text.OnHover(h => text.Foreground = Brush(enabled?.Invoke() == false ? Faint : h ? (blue ? BlueDeep : Ink) : tint));
        if (enabled?.Invoke() == false) text.Foreground = Brush(Faint);
        return text.OnTap(action, title, enabled);
    }

    /// <summary>墨黑胶囊（一页一个）。</summary>
    public static V3Button Dark(string title, Action action, double height = 38, bool enabled = true) => new(title, action, V3Button.Kind.Dark, height) { Enabled = enabled };

    /// <summary>白底细边胶囊。</summary>
    public static V3Button Ghost(string title, Action action, double height = 38, bool enabled = true) => new(title, action, V3Button.Kind.Ghost, height) { Enabled = enabled };

    /// <summary>`ConfirmDialog`：460 宽，标题 17、说明 14，右下取消 + 墨黑确认；无 ×，Esc 关闭。</summary>
    public static V3Overlay Confirm(XamlRoot root, string title, string desc, string confirm, Action onConfirm, string cancel = "取消", UIElement? extra = null, Action? onCancel = null) =>
        V3Overlay.Show(root, close =>
        {
            var stack = VStack(0, Label(title, 17, Ink, Medium).Frame(height: 24), Sans(desc, 14, Sub).LineHeight(22).Wrap().Top(10));
            if (extra is not null) stack.Children.Add(extra);
            var buttons = HStack(10, Ghost(cancel, () => { close(); onCancel?.Invoke(); }, 36), Dark(confirm, () => { close(); onConfirm(); }, 36));
            buttons.HorizontalAlignment = HorizontalAlignment.Right;
            stack.Children.Add(buttons.Top(24));
            return Card(stack, 460, new Thickness(33, 29, 33, 28));
        }, dismissed: null);

    /// <summary>弹窗外壳：白底、圆角 8、细边、阴影。</summary>
    public static Border Card(UIElement child, double width, Thickness padding) => new Border
    {
        Child = child, Width = width, Padding = padding, CornerRadius = new CornerRadius(8),
        Background = Brush(V3.White), BorderBrush = Brush(V3.Cl), BorderThickness = new Thickness(1),
    }.Elevate(32);

    /// <summary>`.mi3-form`：462 宽的表单卡，标题 17（serif 时 20/600）、说明 13；底部分隔线上 72 高按钮行（左侧可放小字）。</summary>
    public static Border Form(string title, string? sub, UIElement content, UIElement? left, UIElement[] foot, double width = 462, bool large = false)
    {
        var stack = VStack(0, Label(title, large ? 20 : 17, Ink, large ? Semibold : Medium).Frame(height: large ? 28 : 24));
        if (sub is not null) stack.Children.Add(Sans(sub, 13, Fnt).Frame(height: 20).Top(6));
        stack.Children.Add(content);
        var right = HStack(10, foot);
        var bar = Columns(10, (Star(), left ?? new Border()), (Auto, right.Align(v: VerticalAlignment.Center)));
        var footer = new Border { Child = bar, Height = 72, Margin = new Thickness(-33, 20, -33, 0), Padding = new Thickness(33, 0, 33, 0), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        stack.Children.Add(footer);
        return Card(stack, width, new Thickness(33, 29, 33, 0));
    }

    /// <summary>页面右上角的提示（Web `Toast`）：用工作区顶部提示。</summary>
    public static void Notice(string title, string? message = null, bool error = false) =>
        V3Toast.Show(title, error ? V3Toast.Kind.Error : V3Toast.Kind.Success, message);

    /// <summary>模拟面试错误文案（Web `MOCK_INTERVIEW_ERROR_MESSAGES`）。</summary>
    public static readonly Dictionary<string, string> Messages = new()
    {
        ["CREDIT_INSUFFICIENT"] = "积分已用完，本次 AI 请求没有发出。",
        ["PAID_CREDIT_REQUIRED"] = "当前额度不能使用这项功能。",
        ["MOCK_INTERVIEW_NOT_FOUND"] = "这场模拟面试不存在或已被删除。",
        ["MOCK_INTERVIEW_IN_PROGRESS"] = "已有一场进行中的模拟面试，请先完成或放弃它。",
        ["MOCK_INTERVIEW_QUESTION_MISMATCH"] = "题目已经变化，请刷新后再作答。",
        ["MOCK_INTERVIEW_STATE_INVALID"] = "当前状态不能执行这个操作，请刷新后重试。",
        ["MOCK_INTERVIEW_RESUME_REQUIRED"] = "这条求职记录没有关联简历，请另选一份简历。",
        ["MOCK_INTERVIEW_RESUME_INVALID"] = "这份简历暂时无法用于模拟面试，请换一份或重新保存后再试。",
        ["MOCK_INTERVIEW_MATERIAL_INVALID"] = "参考资料不可用：最多选择 10 份已解析成功的文字资料。",
        ["MOCK_INTERVIEW_SOURCE_NOT_FOUND"] = "选择的简历、岗位或求职记录不存在。",
        ["MOCK_INTERVIEW_CURSOR_INVALID"] = "列表翻页失败，请刷新后重试。",
        ["MOCK_INTERVIEW_TURN_FAILED"] = "面试官没能生成回复，回答已保存，请重新生成。",
        ["MOCK_INTERVIEW_SPEECH_UNAVAILABLE"] = "语音面试暂不可用，请改用文字面试。",
        ["MOCK_INTERVIEW_SPEECH_SESSION_INVALID"] = "语音识别已过期，请重新录音。",
        ["MOCK_INTERVIEW_SPEECH_EMPTY"] = "没有识别到文字，请重新录音或改用打字。",
        ["MOCK_INTERVIEW_SPEECH_FAILED"] = "语音识别失败，请重录或改用文字。",
        ["DATASET_MEDIA_STORAGE_LIMIT_REACHED"] = "音视频空间已满，录音无法保存。请改用文字作答，或删除不用的录音录像。",
        ["MOCK_INTERVIEW_RECORDING_STORE_FAILED"] = "录音保存失败，请稍后重试提交。",
        ["MOCK_INTERVIEW_RECORDING_DELETE_FAILED"] = "录音删除失败，请稍后重试。",
        ["MOCK_INTERVIEW_TRANSCRIPT_ALREADY_CORRECTED"] = "本场识别稿已经修正过一次。",
        ["MOCK_INTERVIEW_TRANSCRIPT_CORRECTION_REJECTED"] = "修改幅度超过原识别稿的 15%，只能修正错字和术语。",
        ["MOCK_INTERVIEW_RECORDING_NOT_FOUND"] = "录音已删除或不存在。",
        ["MOCK_INTERVIEW_RE_EVALUATE_LIMIT"] = "每道题最多重新评估 3 次。",
        ["MOCK_INTERVIEW_ACTION_NOT_FOUND"] = "这条建议已经不在报告里了，请刷新后重试。",
        ["MOCK_INTERVIEW_PLAN_INCOMPLETE"] = "面试题目没有准备完整，请重试。",
        ["MOCK_INTERVIEW_TASK_INTERRUPTED"] = "后台任务被中断，请重试。",
        ["LLM_MODEL_NOT_CONFIGURED"] = "AI 模型暂未配置，请稍后再试。",
        ["LLM_RESPONSE_INVALID"] = "AI 返回的内容无法使用，请重试。",
        ["VALIDATION_ERROR"] = "提交的内容不符合要求，请检查后重试。",
        ["UNAUTHORIZED"] = "登录已过期，请重新登录。",
        ["INTERVIEW_QUESTIONS_NOT_FOUND"] = "没找到面试问题，换一份文字稿试试。",
    };

    public static string Error(Exception error)
    {
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) { App.Session.ReportAuthenticationFailure(); return Messages["UNAUTHORIZED"]; }
        if (error is ApiException api && Messages.TryGetValue(api.Code, out var message)) return message;
        return "操作没有完成，请稍后重试。";
    }

    /// <summary>LCG（与 Web 相同的常数），种子由 FNV-1a 散列得到。</summary>
    public static Func<double> Rand(string seed)
    {
        uint value = 2166136261;
        foreach (var unit in seed.EnumerateRunes()) value = unchecked((value ^ (uint)(unit.Value & 0xFFFF)) * 16777619);
        if (value == 0) value = 1;
        return () => { value = unchecked(value * 1664525 + 1013904223); return value / 4294967296.0; };
    }
}

/// <summary>
/// 声纹画布（Web `Voiceprint.tsx`）：按 viewBox 坐标画一排圆角竖条，`xMaxYMid slice` 铺满并右对齐；尺寸变化时重画。
/// </summary>
internal sealed class MockWave : Canvas
{
    const double RowW = 1000, RowStep = 5, BarW = 2.6, RowScale = 1.625, GhostStep = 5.5;
    const int RowBars = 200, OrangeBars = 17;
    static readonly double[] GhostShape = [6, 23, 11, 10, 22, 19, 16, 28, 31, 26, 32, 31, 38, 18, 22, 32, 30, 10, 26, 18, 27, 23, 8, 15, 23, 19, 19, 19, 28, 31, 19, 19, 36, 21, 15, 20, 24, 19, 39, 25, 28, 30, 8, 12, 17, 15, 13, 9, 23, 7, 15, 15, 25, 31, 19, 10, 14, 10, 10, 10, 7, 8, 7, 3, 5, 3];
    const int GhostBlue = 53;
    static readonly int GhostBars = (int)(RowW / GhostStep);

    readonly double[] _heights;
    readonly double _viewH, _step;
    readonly int _blueCount;
    readonly double _opacity;

    MockWave(double[] heights, double viewH, double step, int blueCount, double opacity)
    {
        (_heights, _viewH, _step, _blueCount, _opacity) = (heights, viewH, step, blueCount, opacity);
        Height = viewH;
        IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        SizeChanged += (_, e) => Draw(e.NewSize);
    }

    /// <summary>首页一条回答的声纹：蓝色是答出来的部分，橙色是停下的那段。</summary>
    public static MockWave Row(string seed, double opacity = 1)
    {
        var next = MP.Rand(seed);
        var blue = Enumerable.Range(0, RowBars - OrangeBars).Select(_ => 10 + next() * 25);
        var orange = Enumerable.Range(0, OrangeBars).Select(i => 3 + (0.8 + next() * 0.2) * 24 * Math.Pow(1 - (double)i / OrangeBars, 1.4));
        return new MockWave(blue.Concat(orange).Select(h => h * RowScale).ToArray(), 60, RowStep, RowBars - OrangeBars, opacity);
    }

    /// <summary>还没发生的一行：一段淡声纹，shift 让每行错开。</summary>
    public static MockWave Ghost(int shift)
    {
        var tail = GhostShape.Length - GhostBlue;
        var heights = Enumerable.Range(0, GhostBars).Select(i =>
        {
            var at = i - (GhostBars - tail);
            return (at >= 0 ? GhostShape[GhostBlue + at] : GhostShape[(i + shift * 17) % GhostBlue]) * RowScale;
        }).ToArray();
        return new MockWave(heights, 64, GhostStep, GhostBars - tail, 1);
    }

    void Draw(Windows.Foundation.Size size)
    {
        Children.Clear();
        if (size.Width <= 0) return;
        var scale = Math.Max(size.Width / RowW, size.Height / _viewH);
        var dx = size.Width - RowW * scale;
        var dy = (size.Height - _viewH * scale) / 2;
        var count = _heights.Length;
        for (var i = 0; i < count; i++)
        {
            var x = RowW - BarW - (count - 1 - i) * _step;
            var left = dx + x * scale;
            if (left + BarW * scale <= 0) continue;
            var bar = new Rectangle
            {
                Width = BarW * scale, Height = _heights[i] * scale, RadiusX = 1.3 * scale, RadiusY = 1.3 * scale,
                Fill = Brush(Alpha(i < _blueCount ? MP.LightBlue : MP.Orange, _opacity)),
            };
            SetLeft(bar, left);
            SetTop(bar, dy + (_viewH - _heights[i]) / 2 * scale);
            Children.Add(bar);
        }
        Clip = new Microsoft.UI.Xaml.Media.RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, size.Width, size.Height) };
    }
}

/// <summary>面试中的大声纹（900 × 100）：You 跟着麦克风，Interviewer 说话时持续起伏，Rest 静止灰色，Flat 一条线。</summary>
internal sealed class MockLiveWave : Canvas
{
    public enum Tone { Interviewer, You, Rest, Flat }
    const int Bars = 150;
    const double Step = 6, BarW = 3, WaveH = 100, MinH = 3, MaxH = 80;
    readonly Rectangle[] _bars = new Rectangle[Bars];
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(0.12) };
    Tone _tone;
    int _frame;

    public MockLiveWave(Tone tone)
    {
        Width = 900; Height = WaveH; IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        for (var i = 0; i < Bars; i++)
        {
            _bars[i] = new Rectangle { Width = BarW, RadiusX = 1.5, RadiusY = 1.5 };
            SetLeft(_bars[i], i * Step + 1);
            Children.Add(_bars[i]);
        }
        _timer.Tick += (_, _) => { _frame++; Apply(Speech(_frame)); };
        Unloaded += (_, _) => _timer.Stop();
        Loaded += (_, _) => { if (_tone == Tone.Interviewer) _timer.Start(); };
        Set(tone);
    }

    static double Envelope(int i) => Math.Pow(Math.Sin(Math.PI * (i + 0.5) / Bars), 0.6);

    static double[] Speech(int frame) => Enumerable.Range(0, Bars).Select(i =>
    {
        var wave = Math.Abs(Math.Sin(i * 0.37 + frame * 0.9) * 0.55 + Math.Sin(i * 0.11 - frame * 0.5) * 0.45);
        var grain = MP.Rand($"{i}:{frame % 7}")();
        return Math.Max(MinH, (wave * 0.75 + grain * 0.25) * MaxH * Envelope(i));
    }).ToArray();

    static readonly double[] Resting = Speech(3).Select(h => Math.Max(MinH, h * 0.38)).ToArray();

    public void Set(Tone tone, IReadOnlyList<double>? values = null)
    {
        _tone = tone;
        var fill = Brush(tone == Tone.You ? MP.Blue : tone == Tone.Interviewer ? MP.Fnt : MP.Faint);
        foreach (var bar in _bars) bar.Fill = fill;
        if (tone == Tone.Interviewer) { if (IsLoaded) _timer.Start(); Apply(Speech(_frame)); return; }
        _timer.Stop();
        Apply(tone switch
        {
            Tone.You => Mic(values ?? []),
            Tone.Rest => Resting,
            _ => Enumerable.Repeat(MinH, Bars).ToArray(),
        });
    }

    static double[] Mic(IReadOnlyList<double> values) => Enumerable.Range(0, Bars).Select(i =>
    {
        var at = (int)((double)i / Bars * values.Count);
        var value = values.Count == 0 ? 0 : values[Math.Min(values.Count - 1, at)];
        return Math.Max(MinH, Math.Min(1, value * 2.4) * MaxH * Envelope(i));
    }).ToArray();

    void Apply(double[] heights)
    {
        for (var i = 0; i < Bars; i++)
        {
            _bars[i].Height = heights[i];
            SetTop(_bars[i], (WaveH - heights[i]) / 2);
        }
    }
}

/// <summary>设备检测的小声纹（165 × 24）。</summary>
internal sealed class MockMiniWave : Canvas
{
    readonly Rectangle[] _bars = new Rectangle[33];
    public MockMiniWave()
    {
        Width = 165; Height = 24; IsHitTestVisible = false;
        for (var i = 0; i < _bars.Length; i++)
        {
            _bars[i] = new Rectangle { Width = 2.6, RadiusX = 1.3, RadiusY = 1.3, Fill = Brush(MP.Blue) };
            SetLeft(_bars[i], i * 5);
            Children.Add(_bars[i]);
        }
        Set([]);
    }

    public void Set(IReadOnlyList<double> values)
    {
        for (var i = 0; i < _bars.Length; i++)
        {
            var value = values.Count == 0 ? 0 : values[Math.Min(values.Count - 1, (int)(i / 33.0 * values.Count))];
            var height = Math.Max(2, Math.Min(1, value * 2.4) * 22);
            _bars[i].Height = height;
            SetTop(_bars[i], 12 - height / 2);
        }
    }
}

/// <summary>一段声音的音量记录：每次音量变化推进一格，最多 64 格。</summary>
internal sealed class MockLevels
{
    readonly List<double> _values = [];
    public IReadOnlyList<double> Values => _values;
    public void Push(double level)
    {
        if (_values.Count >= 64) _values.RemoveAt(0);
        _values.Add(level);
    }
    public void Clear() => _values.Clear();
}

/// <summary>摘要一格（首页、结束页共用）。</summary>
internal sealed record MockTally(string Value, string? Unit, string Caption, string Text, Color? Tone = null, Color? Dot = null)
{
    /// <summary>`.mi3-tally`：大数 + 单位 + 标签，下面一行说明（带点时是蓝 / 橙小圆点）。</summary>
    public FrameworkElement View()
    {
        var head = HStack(0, Number(Value, 28, Unit is null ? MP.Faint : MP.Ink, Semibold).Align(v: VerticalAlignment.Bottom));
        if (Unit is not null) head.Children.Add(Sans(Unit, 13, MP.Fnt).Align(v: VerticalAlignment.Bottom).Pad(3, 0, 0, 5));
        head.Children.Add(Label(Caption, 13, Tone ?? MP.Ink, Medium).Align(v: VerticalAlignment.Bottom).Pad(Unit is null ? 5 : 8, 0, 0, 5));
        head.Height = 38;
        var text = Sans(Text, 13, Dot is null ? MP.Fnt : MP.Sub).LineHeight(20).Wrap();
        UIElement line = Dot is { } dot
            ? Columns(8, (Auto, new Ellipse { Width = 6, Height = 6, Fill = Brush(dot), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 7, 0, 0) }), (Star(), text))
            : text;
        return VStack(4, head, line);
    }

    /// <summary>标题行 + 分隔线 + 四列（窄于 860 两列）。</summary>
    public static FrameworkElement Section(string title, IReadOnlyList<MockTally> items, double width, Action? records = null)
    {
        var columns = width < 860 ? 2 : 4;
        var grid = new Grid { ColumnSpacing = 24, RowSpacing = 14 };
        for (var c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        for (var i = 0; i < items.Count; i++)
        {
            if (i % columns == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var cell = items[i].View();
            Microsoft.UI.Xaml.Controls.Grid.SetRow(cell, i / columns);
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(cell, i % columns);
            grid.Children.Add(cell);
        }
        var head = Columns(8, (Star(), Sans(title, 13, MP.Fnt)), (Auto, records is null ? new Border() : MP.Link("全部记录 ›", records))).Frame(height: 18);
        return new Border
        {
            Child = VStack(4, head, grid), Padding = new Thickness(0, 17, 0, 0),
            BorderBrush = Brush(MP.Line), BorderThickness = new Thickness(0, 1, 0, 0),
        };
    }
}

/// <summary>页面的请求生命周期：页面卸下或换了账号就取消，换账号时清空页面。</summary>
internal sealed class MockViewLifetime : IDisposable
{
    readonly UserControl _view; readonly Action _clear; readonly string? _owner;
    readonly CancellationTokenSource _cancel = new();
    bool _disposed;
    public MockViewLifetime(UserControl view, Action clear)
    {
        (_view, _clear, _owner) = (view, clear, App.Session.User?.Id);
        App.Session.PropertyChanged += Changed;
        view.Unloaded += Unloaded;
    }
    public bool Alive => !_disposed && _owner == App.Session.User?.Id;
    public CancellationToken Token => _cancel.Token;
    void Changed(object? sender, PropertyChangedEventArgs e) { if (_owner != App.Session.User?.Id) { Dispose(); _clear(); } }
    void Unloaded(object sender, RoutedEventArgs e) => Dispose();
    public async Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null, Dictionary<string,string>? query = null)
    {
        var result = await App.Session.Api.CareerRequestAsync(path, method, query, body, Token);
        if (!Alive) throw new OperationCanceledException();
        return result;
    }
    public void Dispose() { if (_disposed) return; _disposed = true; _cancel.Cancel(); App.Session.PropertyChanged -= Changed; _view.Unloaded -= Unloaded; }
}
