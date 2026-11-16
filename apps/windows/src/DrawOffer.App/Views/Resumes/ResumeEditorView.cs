using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Paper;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using S = DrawOffer.App.Views.Resumes.EditorJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 简历编辑（Figma 07.0，Mac `ResumeEditorView.swift`，Web `ResumeWorkbench`）：纸面即编辑器，与 Web 同一套 TipTap 编辑器、分页、斜杠菜单与选区工具栏
/// （<see cref="ResumeEditorPaperView"/>）。整页铺满窗口、没有侧栏：48 高白色标题栏（← 我的简历、撤销重做 | 标题 | 模板、导出 PDF），
/// #F4F4F1 画布上纸面上沿一行规格（字体 · 字号 · 行距 · 共 N 页 ⌄ ｜ 检查简历）；左边模板栏（07.1）、规格行下的排版卡片（06.2），
/// 纸右边 400 宽一列对话（改这一条 12.1–12.6、检查简历 12.7–12.11、新建引导 05）。
/// 保存提交 `PUT /api/resumes/{id}` 的 data、style 与 base_lock_version；冲突时提示重新载入，不覆盖他处的修改。不显示“已保存”，自动保存失败才在画布上方出提示卡。
/// </summary>
public sealed class ResumeEditorView : UserControl
{
    readonly string _resumeId;
    readonly Action _close;

    JsonNode? _record;
    JsonNode? _saved, _doc, _savedStyle, _style;
    string _title = "";
    bool _loading = true;
    string? _error;
    string? _notice;
    bool _saving, _conflict;
    string? _paperNote;
    /// <summary>可编辑纸面：`paperSeed` 变化时重新载入（打开、换模板、重新载入）；版式在排版卡片改动时按 `styleRevision` 下发。</summary>
    JsonNode? _paperSeed;
    int _paperGeneration, _styleRevision;
    /// <summary>纸面最近一次回报的版式：与它相同的变化来自纸面本身，不再下发。</summary>
    JsonNode? _paperStyle;
    readonly ResumeEditorChannel _channel = new();
    bool _canUndo, _canRedo;
    double _zoom = 1.0;
    double? _zoomBadge;
    /// <summary>Web 存在 localStorage 的「页面排列」，只影响编辑时浏览方向。</summary>
    readonly string _pageArrangement = EditorPreferences.Read("workbench.pageArrangement", "vertical");
    /// <summary>当前打开的面板：type 排版卡片 / template 模板栏 / check 检查简历 / line 改这一条 / guide 新建引导。</summary>
    string? _panel;
    /// <summary>自动保存：停顿后串行保存；失败时显示提示卡和重试。</summary>
    CancellationTokenSource? _autosaveTask;
    bool _saveFailed, _exporting;
    List<string> _importWarnings = [];
    /// <summary>这份简历的写作引导（进入编辑器先读；没有引导时不显示入口，进行中时自动展开）。</summary>
    JsonNode? _guide;
    /// <summary>检查简历的结果：收起面板也留着，上沿显示还剩几处；重新载入或换模板时清掉。</summary>
    readonly ResumeCheckState _check = new();
    /// <summary>纸面上报的光标所在行（12.1：行旁“改这一条 Ctrl+K”）；不在可改的行上或正在打字时为 null。</summary>
    PaperLine? _paperLine;
    /// <summary>纸面实际页数（规格行“共 N 页”、检查简历的 page_count）。</summary>
    int _pageCount = 1;
    /// <summary>07.2 模板悬停预览：纸面临时换成的那套模板名；规格行换成灰字“预览：… · 点击换上”。</summary>
    string? _templatePreviewName;
    CancellationTokenSource? _templatePreviewTask;
    /// <summary>同一份正文下各模板的预览结果；正文一改就作废。</summary>
    readonly Dictionary<string, JsonNode> _templatePreviewCache = [];
    /// <summary>下发给纸面的检查标记 / 预览（变了才发）。</summary>
    string _sentMarks = "", _sentDecor = "";
    int? _revealed;

    // 跨重绘保留的部件：纸面（光标与撤销历史）、标题框（焦点）、各面板（自身的加载与对话状态）
    ResumeEditorPaperView? _paper;
    int _paperBuilt = -1;
    readonly TextBox _titleBox = new();
    TemplateSwitchSheet? _templatePanel;
    TypeSettingsCard? _typeCard;
    ResumeGuidePanel? _guidePanel;
    ResumeCheckPanel? _checkPanel;
    ResumeLineChat? _lineChat;
    V3Overlay? _leaveDialog;
    readonly Grid _root = new();
    // 重绘只换这些槽位之外的部件：纸面与标题框始终挂在同一个父容器上（换父会让 WebView2 重载、标题框失焦）
    readonly Grid _paperSlot = new();
    readonly Border _titleSlot = new();
    int _zoomToken;

    bool Dirty => _record is not null && (!S.Same(_doc, _saved) || !S.Same(_style, _savedStyle) || _title != _record.Text("title"));
    List<JsonNode?> Sections => S.Arr(_doc.Get("sections"));
    string TemplateKey => _style.Get("template_snapshot").Text("template_key");
    bool Busy => _saving;

    static IApiClient Api => App.Session.Api;

    public ResumeEditorView(string resumeId, Action close)
    {
        _resumeId = resumeId;
        _close = close;
        Content = _root;
        _titleSlot.Child = _titleBox;
        ConfigureTitle();
        ConfigureKeys();
        Render();
        // `.task`：只在第一次出现时读取
        var started = false;
        Loaded += async (_, _) => { if (started) return; started = true; await Load(); await LoadGuide(); };
        // onDisappear：编辑器真正离开界面时取消自动保存并关闭纸面
        Unloaded += (_, _) =>
        {
            _autosaveTask?.Cancel(); _templatePreviewTask?.Cancel(); _paper?.Dispose(); _paper = null;
            (App.NativeWindow as MainWindow)?.SetPassthrough([]);
        };
    }

    // MARK: Body

    /// <summary>
    /// 状态变化后重画。外层结构只建一次（<see cref="BuildFrame"/>）：纸面槽位与标题框始终挂在同一个父容器上，
    /// 这里只替换标题栏两侧、规格行、导入提示、状态层与画布上的面板。
    /// </summary>
    void Render()
    {
        if (_root.Children.Count == 0) BuildFrame();
        RenderToolbar();
        _banner.Child = _importWarnings.Count > 0 ? ImportBanner() : null;
        _state.Children.Clear();
        _state.Visibility = Visibility.Visible;
        if (_loading && _record is null)
            _state.Children.Add(VStack(10, new ProgressRing { IsActive = true, Width = 24, Height = 24 }, Sans("正在读取简历…", 13, Sub)).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        else if (_record is null)
        {
            var retry = new V3Button("重试", () => _ = Load(), V3Button.Kind.Ghost);
            retry.HorizontalAlignment = HorizontalAlignment.Center;
            _state.Children.Add(VStack(10, Sans(_error ?? "简历读取失败。", 13, Red).Align(HorizontalAlignment.Center), retry).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        }
        else _state.Visibility = Visibility.Collapsed;
        RenderCanvas();
        SyncCheck();
    }

    static readonly Color Canvas = Hex(0xF4F4F1);
    readonly Border _leftHost = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
    readonly Border _rightHost = new() { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    readonly Border _banner = new();
    readonly Grid _state = new() { Background = Brush(Canvas) };
    readonly Grid _overlay = new();
    /// <summary>07.1 模板栏：编辑器左边一整列。</summary>
    readonly Border _railHost = new() { VerticalAlignment = VerticalAlignment.Stretch };
    /// <summary>纸面这一列（规格行 + 纸面），对话列打开时右边让出位置。</summary>
    readonly Grid _paperColumn = new();
    readonly Border _specHost = new() { HorizontalAlignment = HorizontalAlignment.Center, Height = 32, Margin = new Thickness(0, 8, 0, 0) };
    /// <summary>06.2 排版卡片：规格行下面。</summary>
    readonly Border _cardHost = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 44, 0, 16) };
    /// <summary>12.x 纸右边一列：改这一条 / 检查简历 / 新建引导。</summary>
    readonly Border _columnHost = new() { Width = ResumeTalk.ColumnWidth, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Stretch };
    /// <summary>纸面上的「改这一条」入口层（与纸面同一坐标）。</summary>
    readonly Canvas _triggerLayer = new();
    readonly Grid _main = new();

    void BuildFrame()
    {
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = Star() });
        // 标题栏：48 高白底，下边线 #ECEBE6；标题居中
        var center = new Border { Child = _titleSlot, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 560 };
        // 右上角留出系统最小化 / 最大化 / 关闭（3 × 46）；标题栏其余位置可拖动窗口，按钮与标题设为穿透区
        var head = new Grid { Padding = new Thickness(12, 0, 12 + 138, 0) };
        foreach (var part in new FrameworkElement[] { _leftHost, _rightHost, _titleSlot }) part.SizeChanged += (_, _) => UpdateCaption();
        head.Children.Add(_leftHost);
        head.Children.Add(_rightHost);
        head.Children.Add(center);
        _root.Children.Add(new Border { Child = head, Height = 48, BorderBrush = Brush(Hex(0xECEBE6)), BorderThickness = new Thickness(0, 0, 0, 1), Background = Brush(V3.White) });
        Grid.SetRow(_banner, 1);
        _root.Children.Add(_banner);

        // 画布：左边模板栏 | 纸面一列（规格行 + 纸面）与浮在上面的排版卡片、对话列
        var area = new Grid { Background = Brush(Canvas) };
        area.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        area.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        area.Children.Add(_railHost);
        _paperColumn.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _paperColumn.RowDefinitions.Add(new RowDefinition { Height = Star() });
        _paperColumn.Children.Add(_specHost);
        Grid.SetRow(_paperSlot, 1);
        _paperColumn.Children.Add(_paperSlot);
        Grid.SetRowSpan(_cardHost, 2);
        _paperColumn.Children.Add(_cardHost);
        _main.Children.Add(_paperColumn);
        _main.Children.Add(_columnHost);
        _main.Children.Add(_overlay);
        Grid.SetColumn(_main, 1);
        area.Children.Add(_main);
        Grid.SetColumnSpan(_state, 2);
        area.Children.Add(_state);
        _main.SizeChanged += (_, _) => Relayout();
        Grid.SetRow(area, 2);
        _root.Children.Add(area);
    }

    /// <summary>标题栏里的按钮与标题框可点（窗口内容铺到了标题栏）。</summary>
    void UpdateCaption() => (App.NativeWindow as MainWindow)?.SetPassthrough([_leftHost, _rightHost, _titleSlot]);

    /// <summary>`.confirmationDialog("放弃未保存的修改？")`。</summary>
    void ConfirmLeave()
    {
        if (XamlRoot is null || _leaveDialog is { IsOpen: true }) return;
        _leaveDialog = V3Overlay.Show(XamlRoot, dismiss => V3Dialog.Make(V3DialogHead.Make("放弃未保存的修改？"),
            [new V3Button("继续编辑", dismiss, V3Button.Kind.Ghost), new V3Button("放弃修改", () => { dismiss(); _close(); }, V3Button.Kind.Danger)], dismiss, width: 400));
    }

    // MARK: Canvas

    bool TypeOpen => _panel == "type" && ResumeTypeSettings.Read(_style) is not null;
    bool TemplateOpen => _panel == "template";
    bool CheckOpen => _panel == "check";
    bool LineOpen => _panel == "line" && _lineChat is not null;
    bool GuideOpen => _panel == "guide" && _guide is not null;
    bool ColumnOpen => GuideOpen || CheckOpen || LineOpen;
    /// <summary>07.1 模板栏宽 356；12.x 对话列 400、距纸 52。</summary>
    const double ColumnGap = 52;

    /// <summary>纸与右边一列当成一组居中：纸面宽 794 × 缩放；放不下时对话列贴右 24。</summary>
    (double PaperTrailing, double ColumnX) ColumnLayout(double width)
    {
        var paper = 794 * _zoom;
        var group = paper + ColumnGap + ResumeTalk.ColumnWidth;
        if (width >= group + 80)
        {
            var left = (width - group) / 2;
            return (Math.Max(0, width - 2 * left - paper), left + paper + ColumnGap);
        }
        return (ResumeTalk.ColumnWidth + ColumnGap, width - ResumeTalk.ColumnWidth - 24);
    }

    double SpecWidth => Math.Min(794 * _zoom + 12, 900);

    /// <summary>按当前宽度摆放纸面一列、对话列和排版卡片（窗口变宽变窄、缩放、开合面板时调用）。</summary>
    void Relayout()
    {
        var width = _main.ActualWidth;
        var layout = ColumnLayout(width);
        var trailing = ColumnOpen ? layout.PaperTrailing : 0;
        _paperColumn.Margin = new Thickness(0, 0, trailing, 0);
        _columnHost.Margin = new Thickness(Math.Max(0, layout.ColumnX), 44, 0, 0);
        _specHost.Width = SpecWidth;
        var specLeft = (width - trailing - SpecWidth) / 2;
        _cardHost.Margin = new Thickness(Math.Max(8, specLeft - 14), 44, 0, 16);
        RenderTrigger();
    }

    void RenderCanvas()
    {
        UpdatePreview();
        var ready = _record is not null;
        _specHost.Child = ready ? SpecBar() : null;

        // 07.1 模板栏
        if (ready && TemplateOpen)
        {
            _templatePanel ??= new TemplateSwitchSheet(ApplyTemplate, () => { _panel = null; Render(); }, PreviewTemplate);
            _templatePanel.Update(TemplateKey, Busy || _conflict);
            if (_railHost.Child != _templatePanel) { Detach(_templatePanel); _railHost.Child = _templatePanel; }
        }
        else _railHost.Child = null;

        // 06.2 排版卡片
        if (ready && TypeOpen && ResumeTypeSettings.Read(_style) is { } settings)
        {
            _typeCard ??= new TypeSettingsCard(next => { SetStyle(next.Apply(_style)); Render(); },
                order => _channel.Send(ResumeEditorCommand.Reorder(order)),
                (id, title) => _channel.Send(ResumeEditorCommand.Rename(id, title)),
                id => _channel.Send(ResumeEditorCommand.Remove(id)),
                id => Sections.FirstOrDefault(x => x.NodeKey() == id) is { } section ? SectionLabel(section) : "模块");
            _typeCard.Update(settings, Sections, ResumeLayout.Columns(_doc, _style), Pages, Busy);
            if (_cardHost.Child != _typeCard) { Detach(_typeCard); _cardHost.Child = _typeCard; }
            _cardHost.Visibility = Visibility.Visible;
        }
        else { _cardHost.Child = null; _cardHost.Visibility = Visibility.Collapsed; }

        // 12.x 纸右边一列
        FrameworkElement? column = null;
        if (ready && GuideOpen && _guide is { } guide)
        {
            // 面板只建一次，之后用 Update 推送最新的引导与正文
            if (_guidePanel is not null) _guidePanel.Update(guide, _doc ?? new JsonObject());
            _guidePanel ??= new ResumeGuidePanel(_resumeId, guide, value => { _guide = value; Render(); }, _doc ?? new JsonObject(),
                _record.Get("template_id").String(), SaveBeforeWrite, resume => _ = Apply(resume),
                before => { SetDoc(before); _channel.ReplaceData(before); Render(); }, () => _ = ExportPdf(), () => { _panel = null; Render(); });
            column = _guidePanel;
        }
        else if (ready && CheckOpen)
        {
            _checkPanel ??= new ResumeCheckPanel(_resumeId, () => _doc, SectionLabel, () => Pages, _check, Write, () => { RenderToolbar(); _specHost.Child = SpecBar(); SyncCheck(); },
                () => { _panel = null; Render(); });
            column = _checkPanel;
        }
        else if (ready && LineOpen) column = _lineChat;
        if (!ReferenceEquals(_columnHost.Child, column)) { if (column is not null) Detach(column); _columnHost.Child = column; }
        _columnHost.Visibility = column is null ? Visibility.Collapsed : Visibility.Visible;
        if (!CheckOpen) _checkPanel = null;
        if (!GuideOpen) _guidePanel = null;
        if (!TemplateOpen) _templatePanel = null;
        if (!TypeOpen) _typeCard = null;

        _overlay.Children.Clear();
        if (_saveFailed)
        {
            var notice = SaveNotice();
            notice.HorizontalAlignment = HorizontalAlignment.Center;
            notice.VerticalAlignment = VerticalAlignment.Top;
            notice.Margin = new Thickness(0, 15, 0, 0);
            _overlay.Children.Add(notice);
        }
        if (_zoomBadge is { } badge) _overlay.Children.Add(ZoomFeedback(badge));
        _overlay.IsHitTestVisible = _saveFailed;
        Relayout();
    }

    /// <summary>检查简历、改这一条写回正文：交给纸面并让检查面板按纸面现状结算。</summary>
    void Write(JsonNode next)
    {
        SetDoc(next);
        _channel.ReplaceData(next);
        _checkPanel?.DocumentChanged();
        Render();
    }

    /// <summary>`.wb3-save-notice`：420×64 白卡，圆角 12，红色 16 圆圈「!」、标题与原因、重试保存。</summary>
    Border SaveNotice()
    {
        var mark = new Border
        {
            Width = 16, Height = 16, CornerRadius = new CornerRadius(8), BorderBrush = Brush(Red), BorderThickness = new Thickness(1.4), Margin = new Thickness(0, 2, 0, 0),
            VerticalAlignment = VerticalAlignment.Top, Child = Number("!", 10, Red, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        var texts = VStack(3, Sans("保存失败", 13, Txt, Medium), Sans(_error ?? "修改仍保留在本页，可以重试保存。", 11.5, Sub));
        var retry = new V3Button("重试保存", () => _ = Save(), V3Button.Kind.Ghost, height: 30) { Enabled = !_saving };
        retry.VerticalAlignment = VerticalAlignment.Top;
        var row = Columns(10, (Auto, mark), (Star(), texts), (Auto, retry));
        return new Border
        {
            Child = row, Padding = new Thickness(16, 13, 16, 13), Width = 420, Height = 64, Background = Brush(V3.White),
            CornerRadius = new CornerRadius(12), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        }.Elevate(12);
    }

    /// <summary>`.workbench-zoom-feedback`：居中 104×68 的深色半透明块，等宽数字百分比。</summary>
    static Border ZoomFeedback(double value)
    {
        var percent = (int)Math.Round(value * 100, MidpointRounding.AwayFromZero);
        var text = new TextBlock
        {
            Text = $"{percent}%", FontSize = 20, FontWeight = Semibold, FontFamily = new FontFamily("Cascadia Mono,Consolas"), Foreground = Brush(V3.White),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        var ink = Color.FromArgb(255, 15, 18, 22);
        var badge = new Border
        {
            Child = text, Padding = new Thickness(18, 0, 18, 0), MinWidth = 104, MinHeight = 68, CornerRadius = new CornerRadius(12),
            Background = Brush(Alpha(ink, 0.84)), IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        }.Elevate(21);
        AutomationProperties.SetName(badge, $"缩放 {percent}%");
        return badge;
    }

    /// <summary>Web `previewScale`：0.5–1.6；按钮与快捷键按 0.1 取整，滚轮按页面给的步进。</summary>
    void SetZoom(double value, bool step = true)
    {
        _zoom = Math.Min(1.6, Math.Max(0.5, step ? Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10 : value));
        _zoomBadge = _zoom;
        _paper?.SetView(_zoom, _pageArrangement == "horizontal");
        var token = ++_zoomToken;
        var shown = _zoom;
        _ = Task.Delay(900).ContinueWith(_ => DispatcherQueue.TryEnqueue(() => { if (token == _zoomToken && _zoomBadge == shown) { _zoomBadge = null; Render(); } }), TaskScheduler.Default);
        Render();
    }

    Border ImportBanner()
    {
        var close = HeadIconStyle.Make("xmark", 12, 22, 6, "关闭导入质量提示", () => { _importWarnings = []; Render(); });
        close.VerticalAlignment = VerticalAlignment.Top;
        var texts = VStack(2,
            Sans("请检查导入结果", 12.5, Txt, Semibold),
            Sans(string.Join("；", _importWarnings.Select(ImportWarningText)), 12, Sub).Wrap());
        var icon = Icon("exclamationmark.triangle", 13, Orange);
        icon.VerticalAlignment = VerticalAlignment.Top;
        return new Border { Child = Columns(10, (Auto, icon), (Star(), texts), (Auto, close)), Padding = new Thickness(12), Background = Brush(OrangeSoft) };
    }

    // MARK: Toolbar & spec bar

    /// <summary>
    /// Figma 07.0 标题栏：左「← 我的简历」13/500、撤销 / 重做 28 图标钮；中简历标题 13/500 居中（最宽 560）；
    /// 右无边框「模板」「导出 PDF」（编辑器里不用黑色按钮）。冲突时右边多一个「重新载入」。
    /// </summary>
    void RenderToolbar()
    {
        var back = ToolbarButton("我的简历", "arrow.left", Leave, label: "返回我的简历", strong: true);
        var undo = HeadIconStyle.Make("arrow.uturn.backward", 13, 28, 6, "撤销（Ctrl+Z）", () => _channel.Send(ResumeEditorCommand.Undo), enabled: _canUndo && !Busy);
        var redo = HeadIconStyle.Make("arrow.uturn.forward", 13, 28, 6, "重做（Ctrl+Y）", () => _channel.Send(ResumeEditorCommand.Redo), enabled: _canRedo && !Busy);
        _leftHost.Child = HStack(4, back, HStack(0, undo, redo).Pad(4, 0, 0, 0));

        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (_conflict) right.Children.Add(ToolbarButton("重新载入", "arrow.clockwise", () => _ = Load(), strong: true));
        right.Children.Add(ToolbarButton("模板", "square.grid.2x2", () => TogglePanel("template"), label: "简历模板",
            enabled: !Busy && !_conflict && _record is not null, pressed: TemplateOpen));
        right.Children.Add(ToolbarButton(_exporting ? "导出中…" : "导出 PDF", "square.and.arrow.up", () => _ = ExportPdf(), enabled: !_exporting && _record is not null));
        _rightHost.Child = right;
    }

    /// <summary>
    /// 无边框工具按钮（Windows 稿 CommandBar AppBarButton 观感）：平时没有底色和描边，悬停 5% 黑底、按下或对应面板打开时 8% 黑底，圆角 6；
    /// 图标 12.5 + 文字 13/500，高 28。
    /// </summary>
    static Border ToolbarButton(string title, string? symbol, Action action, string? label = null, bool enabled = true, bool pressed = false, bool strong = false,
        double size = 13, FontWeight? weight = null, Color? tint = null, Color? fill = null)
    {
        var icon = symbol is null ? null : Icon(symbol, size - 1, Sub);
        var text = Sans(title, size, Sub, weight ?? Medium);
        text.VerticalAlignment = VerticalAlignment.Center;
        icon?.Also(i => i.VerticalAlignment = VerticalAlignment.Center);
        var button = new Border { Child = HStack(6, icon, text), Height = symbol is null || size >= 13 ? 28 : 24, Padding = new Thickness(8, 0, 8, 0), CornerRadius = new CornerRadius(6) };
        var hover = false;
        void Paint()
        {
            var ink = tint ?? (!enabled ? Fnt2 : strong || pressed || hover ? Txt : Sub);
            text.Foreground = Brush(ink);
            if (icon is not null) icon.Foreground = Brush(ink);
            button.Background = Brush(fill ?? (pressed ? Alpha(Hex(0x000000), 0.08) : enabled && hover ? Alpha(Hex(0x000000), 0.05) : Clear));
        }
        button.OnHover(h => { hover = h; Paint(); });
        button.OnTap(action, label ?? title, () => enabled);
        if (pressed) AutomationProperties.SetItemStatus(button, "已选中");
        Paint();
        return button;
    }

    /// <summary>
    /// Figma 07.0「Editor Spec Bar」：纸面上沿一行，宽度跟纸一样。左：字体 · 字号 · 行距 · 共 N 页 ⌄（无边框，点开排版卡片）；
    /// 右：「检查简历」（检查中蓝字浅蓝底“检查 · 第 n / m 处”，收起后“检查 · 剩 N 处”），有写作引导时它左边多一个「引导」。
    /// </summary>
    Grid SpecBar()
    {
        UIElement left;
        if (_templatePreviewName is { } name)
        {
            // 07.2：悬停预览时左边这一格临时换成灰字状态（不是按钮），移开恢复
            var hint = HStack(5, Sans($"预览：{name} · 点击换上", 12.5, Fnt), Icon("chevron.up.chevron.down", 9, Fnt).Align(v: VerticalAlignment.Center));
            hint.Height = 24;
            hint.Padding = new Thickness(6, 0, 6, 0);
            left = hint;
        }
        else if (ResumeTypeSettings.Read(_style) is { } settings)
        {
            var summary = SpecSummary(settings);
            var button = ToolbarButton(summary, null, () => TogglePanel("type"), label: $"排版：{summary}", enabled: !Busy, pressed: TypeOpen, size: 12.5, weight: Regular, tint: Busy ? Fnt2 : Hex(0x3C3C3A));
            if (button.Child is StackPanel stack) stack.Children.Add(Icon("chevron.up.chevron.down", 9, Sub).Also(i => { i.VerticalAlignment = VerticalAlignment.Center; i.Margin = new Thickness(-1, 0, 0, 0); }));
            button.Padding = new Thickness(6, 0, 6, 0);
            left = button;
        }
        else left = new Border();
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        if (_guide is not null && !GuideOpen)
            right.Children.Add(Spec(ToolbarButton("引导", "bubble.left", () => TogglePanel("guide"), label: "引导创建简历", enabled: !Busy, size: 12.5, weight: Regular)));
        var active = CheckActive;
        right.Children.Add(Spec(ToolbarButton(CheckLabel, "checkmark.circle", () => TogglePanel("check"), label: "检查简历", enabled: !Busy && !_conflict && _record is not null,
            pressed: CheckOpen && !active, size: 12.5, weight: Regular, tint: active ? Blue : null, fill: active ? BlueSoft : null)));
        return Spread(left, right, 8);

        static Border Spec(Border button) { button.Padding = new Thickness(6, 0, 6, 0); return button; }
    }

    /// <summary>正在读或正在看某一处：入口变成蓝字浅蓝底。</summary>
    bool CheckActive => CheckOpen && _check.Phase is ResumeCheckState.Step.Reading or ResumeCheckState.Step.Item;

    /// <summary>12.x：检查中显示“检查 · 第 n / m 处”，收起后显示还剩几处。</summary>
    string CheckLabel
    {
        get
        {
            if (CheckOpen && _check.Phase == ResumeCheckState.Step.Reading) return "检查中…";
            if (_check.Phase == ResumeCheckState.Step.Item) return $"检查 · 第 {_check.Index + 1} / {_check.Findings.Count} 处";
            if (_check.Remaining is int remaining && remaining > 0) return $"检查 · 剩 {remaining} 处";
            return "检查简历";
        }
    }

    /// <summary>Web `WorkbenchSpecRow`：字体 · 字号 · 行距 · 共 N 页（智能一页时为 1 页）。</summary>
    string SpecSummary(ResumeTypeSettings settings)
    {
        var font = ResumeTypeSettings.Fonts.FirstOrDefault(x => x.Value == settings.FontFamily).Label ?? ResumeTypeSettings.Fonts[0].Label;
        return string.Join(" · ", font, $"{settings.FontSize.ToString("0.##", CultureInfo.InvariantCulture)}pt",
            $"行距 {settings.LineHeight.ToString("0.00", CultureInfo.InvariantCulture)}", $"共 {Pages} 页");
    }

    /// <summary>纸面实际页数；智能一页时为 1。</summary>
    int Pages => ResumeTypeSettings.Read(_style)?.SmartOnePage == true ? 1 : Math.Max(1, _pageCount);

    /// <summary>可编辑纸面：`.workbench-paper-scroll` 与纸面缩放都在页面里按 Web 规则实现（Ctrl + 滚轮缩放回报给原生）；Ctrl+= / Ctrl+− / Ctrl+0 缩放并显示百分比。</summary>
    void UpdatePreview()
    {
        if (_paperSeed is not { } seed || _record is not { } record)
        {
            _paperSlot.Children.Clear();
            _paperSlot.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24 });
            return;
        }
        if (_paper is null || _paperBuilt != _paperGeneration)
        {
            // `.id(paperGeneration)`：换代时整块重建
            _paper?.Dispose();
            _paperSlot.Children.Clear();
            _paper = new ResumeEditorPaperView(_resumeId, seed.Get("data"), seed.Get("style"), record.Get("layout_plan"), _styleRevision, _zoom,
                _pageArrangement == "horizontal", _channel, Api, HandlePaper);
            _paperBuilt = _paperGeneration;
            _paperSlot.Children.Add(_paper);
            _sentMarks = ""; _sentDecor = ""; _revealed = null;
        }
        // 纸面之上的入口层与提示条每次重画；纸面本身保持原位
        while (_paperSlot.Children.Count > 1) _paperSlot.Children.RemoveAt(1);
        _paperSlot.Children.Add(_triggerLayer);
        if (_paperNote is { } note)
        {
            _paperSlot.Children.Add(new Border
            {
                Child = Sans(note, 11.5, Orange), Padding = new Thickness(10, 6, 10, 6), Background = Brush(V3.White), CornerRadius = new CornerRadius(14),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 16),
            });
        }
    }

    /// <summary>12.1：只在没开任何面板、没在预览模板时出现；正在打字时纸面不报行，入口自然收起。</summary>
    bool ShowLineTrigger => _panel is null && _templatePreviewName is null && !Busy && !_conflict;

    /// <summary>“改这一条 Ctrl+K”：纸右边 24、比这一行上沿高 20 的 33 高白色胶囊。</summary>
    void RenderTrigger()
    {
        _triggerLayer.Children.Clear();
        if (_paperLine is not { } line || !ShowLineTrigger) return;
        var height = _paperSlot.ActualHeight;
        if (line.Rect.Bottom <= 0 || line.Rect.Top >= height || line.Paper.Right + 24 + 126 > _paperSlot.ActualWidth) return;
        _triggerLayer.Children.Add(ResumeTalk.Trigger(() => OpenLine(line)).At(line.Paper.Right + 24, Math.Max(0, line.Rect.Top - 20)));
    }

    void HandlePaper(ResumeEditorEvent paperEvent)
    {
        switch (paperEvent)
        {
            case ResumeEditorEvent.Changed changed:
                _paperNote = null;
                SetDoc(changed.Data);
                _paperStyle = changed.Style;
                if (!S.Same(changed.Style, _style)) SetStyle(changed.Style);
                _checkPanel?.DocumentChanged();
                break;
            case ResumeEditorEvent.History history: _canUndo = history.CanUndo; _canRedo = history.CanRedo; break;
            case ResumeEditorEvent.Zoom zoom: SetZoom(zoom.Value, step: false); return;
            case ResumeEditorEvent.Key key:
                // 焦点在纸面里时快捷键先到页面：注入脚本把 Ctrl+= / Ctrl+- / Ctrl+0 转回原生
                if (key.Name == "=") SetZoom(_zoom + 0.1); else if (key.Name == "-") SetZoom(_zoom - 0.1); else if (key.Name == "0") SetZoom(1);
                return;
            case ResumeEditorEvent.Ask ask:
                // 选区工具栏「问 AI」：在纸右边开“改这一条”，带上已经写好的要求
                if (FocusUnit(ask.UnitId) is not { } unit) { _paperNote = "这一行暂时不能聚焦修改"; break; }
                var lineId = unit.Lines.Any(x => x.Id == ask.LineId) ? ask.LineId : unit.Lines.FirstOrDefault()?.Id ?? ask.LineId;
                StartLine(new ResumeLineChat.Target(unit, [lineId], Instruction: ask.Instruction));
                break;
            case ResumeEditorEvent.Error error: _paperNote = error.Message; break;
            case ResumeEditorEvent.Line line: _paperLine = line.Value; RenderTrigger(); return;
            case ResumeEditorEvent.LineOpen open: if (ShowLineTrigger || _panel == "line") OpenLine(open.Value); return;
            case ResumeEditorEvent.Pages pages:
                if (_pageCount == pages.Count) return;
                _pageCount = pages.Count;
                break;
            case ResumeEditorEvent.Mark mark:
                var index = _check.Findings.FindIndex(x => x.Id == mark.Key);
                if (index < 0 || _check.Findings[index].Status != ResumeCheck.Status.Open) return;
                _check.Phase = ResumeCheckState.Step.Item;
                _check.Index = index;
                _panel = "check";
                _checkPanel?.Go(index);
                break;
        }
        Render();
    }

    /// <summary>打开“改这一条”：光标所在的那一条，或选中的几条（12.6，同一段里）。</summary>
    void OpenLine(PaperLine line)
    {
        if (FocusUnit(line.UnitId) is not { } unit) { _paperNote = "这一行暂时不能聚焦修改"; Render(); return; }
        var ids = line.LineIds.Where(id => unit.Lines.Any(x => x.Id == id)).ToList();
        if (ids.Count == 0) { _paperNote = "这一行暂时不能聚焦修改"; Render(); return; }
        // 同一处重复触发（纸面和原生同时响应 Ctrl+K）不重开对话
        if (_panel == "line" && _lineChat?.Targets(unit.Id, ids) == true) return;
        StartLine(new ResumeLineChat.Target(unit, ids, ids.Count == 1 ? line.Selection : null));
        Render();
    }

    void StartLine(ResumeLineChat.Target target)
    {
        _lineChat = new ResumeLineChat(_resumeId, target, () => _doc, LineKind(target.Unit.Id), SectionLabel, Write,
            (highlight, preview) => _channel.Send(ResumeEditorCommand.Decorate("line", highlight, preview)),
            () => { _panel = null; _lineChat = null; Render(); });
        _panel = "line";
    }

    /// <summary>改这一条所在的模块类型（技能不给 STAR）。</summary>
    ResumeCheck.Kind LineKind(string id)
    {
        var section = Sections.FirstOrDefault(x => x.NodeKey() == id || S.Arr(x.Get("entries")).Any(e => e.NodeKey() == id));
        return section is null ? ResumeCheck.Kind.Experience : ResumeCheck.KindOf(section.Text("semantic_kind"), SectionLabel(section));
    }

    // MARK: Check marks

    /// <summary>检查结果里每一处对应纸上的哪几行：一条就是这一行，整段是这一段（含条目标题）。</summary>
    List<string>? CheckNodeIds(int index)
    {
        if (index < 0 || index >= _check.Findings.Count) return null;
        var finding = _check.Findings[index];
        if (finding.LineId is { } lineId) return [lineId];
        var lines = _check.Units.FirstOrDefault(x => x.Id == finding.EntryId)?.Lines.Select(x => x.Id) ?? [];
        return [finding.EntryId, .. lines];
    }

    /// <summary>正在看的那一处（面板打开时）。</summary>
    int? CheckCurrent => CheckOpen && _check.Phase == ResumeCheckState.Step.Item && _check.Index >= 0 && _check.Index < _check.Findings.Count
        && _check.Findings[_check.Index].Status == ResumeCheck.Status.Open ? _check.Index : null;

    /// <summary>
    /// 把检查结果同步到纸面：12.7–12.10 纸边小圆圈（空心 = 还没看，蓝 = 正在看，灰 = 看过；都处理完就不画；收起面板后仍留着，点一下打开那一处），
    /// 正在看的那一处——能直接改的把改好的一句放在纸上，并进另一条的放在那一条上，其余高亮这一行 / 整段；并滚到那一处。变了才下发。
    /// </summary>
    void SyncCheck()
    {
        if (_paper is null) return;
        var current = CheckCurrent;
        var marks = new List<PaperMark>();
        if (_check.Remaining is > 0)
            for (var i = 0; i < _check.Findings.Count; i++)
            {
                if (CheckNodeIds(i) is not { } ids) continue;
                var finding = _check.Findings[i];
                var state = finding.Status != ResumeCheck.Status.Open ? PaperMark.State.Done : i == current ? PaperMark.State.Current : PaperMark.State.Pending;
                marks.Add(new PaperMark(finding.Id, ids, state));
            }
        var marksCommand = ResumeEditorCommand.Marks(marks);
        var key = marksCommand.Json.ToJsonString();
        if (key != _sentMarks) { _sentMarks = key; _channel.Send(marksCommand); }

        List<string> highlight = [];
        List<PaperLineChange> preview = [];
        if (current is { } index && CheckNodeIds(index) is { } nodeIds)
        {
            var finding = _check.Findings[index];
            if (finding.Suggestion is not { } suggestion || finding.LineId is not { } lineId || finding.Fix == "delete") highlight = nodeIds;
            else if (finding.Fix == "merge")
            {
                highlight = nodeIds;
                if (finding.MergeInto is { } target) preview = [new PaperLineChange(target, finding.MergeBefore, suggestion, finding.Risky)];
            }
            else preview = [new PaperLineChange(lineId, finding.Before, suggestion, finding.Risky)];
        }
        var decor = ResumeEditorCommand.Decorate("check", highlight, preview);
        var decorKey = decor.Json.ToJsonString();
        if (decorKey != _sentDecor) { _sentDecor = decorKey; _channel.Send(decor); }
        if (current != _revealed)
        {
            _revealed = current;
            if (current is { } at && CheckNodeIds(at) is { } ids) _channel.Send(ResumeEditorCommand.Reveal(ids));
        }
    }

    // MARK: Template preview

    /// <summary>07.2：鼠标停在一套上，纸面临时换成这套（内容还是这份，`template-preview` 不保存）；null 恢复原纸面。</summary>
    void PreviewTemplate(ResumeTemplate? template)
    {
        _templatePreviewTask?.Cancel();
        _templatePreviewTask = null;
        if (template is null || !TemplateOpen || Busy || TemplateSwitchSheet.Key(template) == TemplateKey)
        {
            if (_templatePreviewName is not null) { _templatePreviewName = null; _channel.PreviewTemplate(null); _specHost.Child = SpecBar(); RenderTrigger(); }
            return;
        }
        if (_templatePreviewCache.TryGetValue(template.Id, out var cached))
        {
            _templatePreviewName = template.Name;
            _channel.PreviewTemplate(cached);
            _specHost.Child = SpecBar();
            RenderTrigger();
            return;
        }
        var body = new JsonObject { ["template_id"] = template.Id, ["data"] = ResumeDocument.PrepareForSave(_doc, _saved) };
        var cancel = new CancellationTokenSource();
        _templatePreviewTask = cancel;
        _ = Run();
        async Task Run()
        {
            // 预览失败就停在原纸面，不打扰；点卡片换模板时才报错
            JsonNode? preview;
            try { preview = (await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/template-preview", "POST", body: body)).Get("preview"); }
            catch { return; }
            if (preview is null || cancel.IsCancellationRequested || !TemplateOpen) return;
            _templatePreviewCache[template.Id] = preview;
            _templatePreviewName = template.Name;
            _channel.PreviewTemplate(preview);
            _specHost.Child = SpecBar();
            RenderTrigger();
        }
    }

    /// <summary>选区所在的聚焦单元：条目或没有条目的模块。</summary>
    SectionFocus.Unit? FocusUnit(string id)
    {
        foreach (var section in Sections)
        {
            if (section.NodeKey() == id) return SectionFocus.UnitOfSection(section);
            if (S.Arr(section.Get("entries")).FirstOrDefault(x => x.NodeKey() == id) is { } entry) return SectionFocus.UnitOf(entry);
        }
        return null;
    }

    /// <summary>与 Web `importWarningMessage` 相同的导入质量提示文案。</summary>
    public static string ImportWarningText(string code) => code switch
    {
        "pdf_ocr_applied" => "PDF 已使用 OCR，请核对姓名、日期和数字",
        "pdf_low_text_quality" => "PDF 文本质量偏低，请重点核对遗漏和错字",
        "docx_embedded_images_omitted" => "DOCX 中的图片未导入",
        "docx_textbox_order_may_change" => "DOCX 文本框的阅读顺序可能发生变化",
        "document_heading_structure_missing" => "原文缺少明确章节标题，已按全文识别",
        "source_quote_not_found" => "部分结构化内容无法定位到原文短句",
        "unparsed_work_start_date" => "部分工作开始日期未能识别",
        "unparsed_work_end_date" => "部分工作结束日期未能识别",
        "unmapped_fragments_preserved" => "部分原文已按自定义章节保留，请人工整理",
        "structure_enhancement_unavailable" => "自动分段未完成，请检查板块和经历条目",
        "structure_needs_review" => "部分经历可能识别有误，请检查板块和经历条目",
        _ => "部分内容需要人工核对",
    };

    string SectionLabel(JsonNode? section)
    {
        var title = ResumeDocument.Value(section.Get("title"));
        return title.Length == 0 ? (ResumeDocument.SectionKinds.FirstOrDefault(x => x.Key == section.Text("semantic_kind")).Label ?? "模块") : title;
    }

    // MARK: State changes（SwiftUI `.onChange`）

    void SetDoc(JsonNode? next)
    {
        if (S.Same(next, _doc)) return;
        _doc = next;
        _templatePreviewCache.Clear();
        ScheduleAutosave();
    }

    void SetStyle(JsonNode? next)
    {
        if (S.Same(next, _style)) return;
        _style = next;
        // 排版卡片改的版式下发给纸面；纸面自己回报的（头像尺寸）不再回送
        if (!S.Same(_style, _paperStyle)) { _styleRevision++; _paper?.UpdateStyle(_style, _styleRevision); }
        ScheduleAutosave();
    }

    /// <summary>标题：随内容伸缩（最宽 560、最窄 40），28 高、13/500 居中；悬停灰底，编辑时白底描边。</summary>
    void ConfigureTitle()
    {
        var box = _titleBox;
        box.FontFamily = SansFamily;
        box.FontSize = 13;
        box.FontWeight = Medium;
        box.Foreground = Brush(Txt);
        box.TextAlignment = TextAlignment.Center;
        box.Height = 28;
        box.MinHeight = 0;
        box.MinWidth = 0;
        box.Padding = new Thickness(6, 4, 6, 0);
        box.CornerRadius = new CornerRadius(6);
        box.BorderThickness = new Thickness(1);
        box.Background = Brush(Clear);
        box.BorderBrush = Brush(Clear);
        box.VerticalContentAlignment = VerticalAlignment.Center;
        box.IsSpellCheckEnabled = false;
        box.Resources["TextControlBackgroundPointerOver"] = Brush(Field);
        box.Resources["TextControlBackgroundFocused"] = Brush(V3.White);
        box.Resources["TextControlBorderBrushPointerOver"] = Brush(Clear);
        box.Resources["TextControlBorderBrushFocused"] = Brush(Cl);
        box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(1);
        AutomationProperties.SetName(box, "简历标题");
        box.TextChanged += (_, _) =>
        {
            FitTitle();
            if (box.Text == _title) return;
            _title = box.Text;
            ScheduleAutosave();
        };
    }

    void FitTitle()
    {
        var probe = new TextBlock { Text = _titleBox.Text, FontFamily = SansFamily, FontSize = 13, FontWeight = Medium };
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        _titleBox.Width = Math.Min(560, Math.Max(40, probe.DesiredSize.Width + 14));
    }

    void SetTitle(string value)
    {
        _title = value;
        if (_titleBox.Text != value) _titleBox.Text = value;
        FitTitle();
    }

    /// <summary>
    /// 快捷键（Mac ⌘ → Ctrl）：Ctrl+Z / Ctrl+Y 撤销重做，Ctrl+= / Ctrl+- / Ctrl+0 缩放，Ctrl+K 改这一条，Esc 关闭当前面板。
    /// 焦点在纸面里时按键先到网页：撤销重做由 TipTap 自己处理，缩放由注入脚本转回，Ctrl+K 由页面报 line-open。
    /// </summary>
    void ConfigureKeys()
    {
        void Add(VirtualKey key, VirtualKeyModifiers modifiers, Func<bool> handle)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, e) => e.Handled = handle();
            KeyboardAccelerators.Add(accelerator);
        }
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        Add(VirtualKey.Z, VirtualKeyModifiers.Control, () => { if (!_canUndo || Busy || _titleBox.FocusState != FocusState.Unfocused) return false; _channel.Send(ResumeEditorCommand.Undo); return true; });
        Add(VirtualKey.Y, VirtualKeyModifiers.Control, () => { if (!_canRedo || Busy || _titleBox.FocusState != FocusState.Unfocused) return false; _channel.Send(ResumeEditorCommand.Redo); return true; });
        Add((VirtualKey)187, VirtualKeyModifiers.Control, () => { if (_paper is null) return false; SetZoom(_zoom + 0.1); return true; });
        Add((VirtualKey)189, VirtualKeyModifiers.Control, () => { if (_paper is null) return false; SetZoom(_zoom - 0.1); return true; });
        Add(VirtualKey.Number0, VirtualKeyModifiers.Control, () => { if (_paper is null) return false; SetZoom(1); return true; });
        Add(VirtualKey.K, VirtualKeyModifiers.Control, () => { if (_paperLine is not { } line || !ShowLineTrigger) return false; OpenLine(line); return true; });
        Add(VirtualKey.Escape, VirtualKeyModifiers.None, () =>
        {
            if (_panel is null) return false;
            if (_panel == "line" && _lineChat is { } chat) { chat.Dismiss(); return true; }
            _panel = null;
            Render();
            return true;
        });
    }

    // MARK: Actions

    async Task Apply(JsonNode resume)
    {
        _record = resume;
        _saved = S.Clone(resume.Get("data"));
        _paperStyle = S.Clone(resume.Get("style"));
        _doc = S.Clone(_saved);
        _savedStyle = S.Clone(resume.Get("style"));
        _style = S.Clone(_savedStyle);
        SetTitle(resume.Text("title"));
        _paperNote = null;
        // 换了正文来源（重新载入、换模板），上次检查的行号不再可靠
        _check.Reset();
        _paperLine = null;
        _templatePreviewTask?.Cancel(); _templatePreviewName = null; _templatePreviewCache.Clear();
        if (_panel is "check" or "line") { _panel = null; _lineChat = null; }
        _checkPanel = null;
        var warnings = S.HasKey(resume.Get("import"), "warnings") ? resume.Get("import").Get("warnings") : resume.Get("import_warnings");
        _importWarnings = S.Arr(warnings).Select(x => x.String()).OfType<string>().ToList();
        _saveFailed = false; _canUndo = false; _canRedo = false;
        _paperSeed = new JsonObject { ["data"] = S.Clone(_saved), ["style"] = S.Clone(_savedStyle) };
        _paperGeneration += 1;
        Render();
        await Task.CompletedTask;
    }

    /// <summary>保存成功：更新已保存的基线与记录；保存期间用户继续编辑的内容保留，等下一次自动保存。</summary>
    void ApplySaved(JsonNode resume, (JsonNode? doc, JsonNode? style, string title) pending)
    {
        var editedDuringSave = !S.Same(_doc, pending.doc) || !S.Same(_style, pending.style) || _title != pending.title;
        _record = resume;
        _saved = S.Clone(resume.Get("data"));
        _savedStyle = S.Clone(resume.Get("style"));
        if (editedDuringSave) ScheduleAutosave();
        else
        {
            // 已保存的正文以服务端为准，但不重载纸面（保留光标与撤销历史）
            _doc = S.Clone(_saved);
            SetTitle(resume.Text("title"));
            if (!S.Same(_style, _savedStyle)) { _paperStyle = S.Clone(_savedStyle); _style = S.Clone(_savedStyle); }
        }
    }

    /// <summary>自动保存（Web 串行保存队列）：停顿 1.5 秒后保存；正在保存时等这次完成再排下一次。</summary>
    void ScheduleAutosave()
    {
        if (_record is null || !Dirty || _conflict) return;
        _autosaveTask?.Cancel();
        var task = new CancellationTokenSource();
        _autosaveTask = task;
        _ = Run(task.Token);
        async Task Run(CancellationToken token)
        {
            try { await Task.Delay(1500, token); } catch (OperationCanceledException) { return; }
            while (_saving) { try { await Task.Delay(200, token); } catch (OperationCanceledException) { } if (token.IsCancellationRequested) return; }
            if (token.IsCancellationRequested || !Dirty) return;
            await Save();
        }
    }

    /// <summary>离开编辑器：有未保存修改时先保存，保存失败再询问是否放弃。</summary>
    void Leave()
    {
        if (!Dirty) { _close(); return; }
        _ = Run();
        async Task Run()
        {
            _autosaveTask?.Cancel();
            await Save();
            if (Dirty) ConfirmLeave(); else _close();
        }
    }

    /// <summary>编辑器顶栏“导出 PDF”：先保存当前修改，再按最新 lock_version 导出。</summary>
    async Task ExportPdf()
    {
        if (Dirty) { _autosaveTask?.Cancel(); await Save(); }
        if (Dirty || _record is not { } record || record.Number("lock_version") is not { } number || number != Math.Floor(number)) return;
        var version = (int)number;
        if (App.NativeWindow is not { } window) return;
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(FileName(_title)) };
        picker.FileTypeChoices.Add("PDF", new List<string> { ".pdf" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        var destination = await picker.PickSaveFileAsync();
        if (destination is null) return;
        _exporting = true; _error = null;
        Render();
        try
        {
            if ((Api as HttpApiClient)?.Coordinator is not { } coordinator) throw new InvalidDataException();
            var data = await coordinator.DownloadResumePdfAsync(_resumeId, version);
            await File.WriteAllBytesAsync(destination.Path, data);
            _notice = "已导出 PDF";
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) { App.Session.ReportAuthenticationFailure(); return; }
            if (error is ApiException { Code: "RESUME_PDF_SNAPSHOT_STALE" }) { _error = "简历已在其他设备更新，请重新载入后再导出。"; _conflict = true; }
            else if (error is IOException or UnauthorizedAccessException) _error = "PDF 已生成，但保存到所选位置失败，请换个位置重试。";
            else _error = "导出 PDF 失败，请稍后重试。";
            _paperNote = _error;
        }
        finally { _exporting = false; Render(); }
    }

    /// <summary>引导写入前：有未保存修改先保存；保存失败不写。</summary>
    async Task<bool> SaveBeforeWrite()
    {
        if (Dirty) { _autosaveTask?.Cancel(); await Save(); }
        return !Dirty;
    }

    /// <summary>开合面板（同一时间只开一个）；已结束的引导再次打开时请求重新开启（Web `toggleGuide`）。</summary>
    void TogglePanel(string key)
    {
        if (_panel == "template" && key != "template") PreviewTemplate(null);
        if (_panel == key) { if (key == "template") PreviewTemplate(null); _panel = null; Render(); return; }
        _panel = key;
        _lineChat = null;
        if (key == "guide" && _guide.Text("status") == "dismissed")
        {
            _ = Reopen();
            async Task Reopen()
            {
                try
                {
                    if ((await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/guide", "PUT")).Get("guide") is { } reopened) { _guide = reopened; _guidePanel = null; Render(); }
                }
                catch { }
            }
        }
        Render();
    }

    async Task LoadGuide()
    {
        JsonNode? loaded;
        try { loaded = (await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/guide", "GET")).Get("guide"); } catch { return; }
        if (loaded is null) return;
        _guide = loaded;
        if (loaded.Text("status") == "active") _panel = "guide";
        Render();
    }

    async Task Load()
    {
        _loading = true; _error = null; _conflict = false;
        Render();
        try
        {
            var result = await Api.CareerRequestAsync($"/api/resumes/{_resumeId}", "GET");
            if (result.Get("resume") is not { } resume) throw new InvalidDataException();
            await Apply(resume);
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = ResumeRequest.ErrorMessage(error, "简历读取失败，请稍后重试。");
        }
        finally { _loading = false; Render(); }
    }

    async Task Save()
    {
        if (_record is not { } record || !Dirty || _saving) return;
        var name = _title.Trim();
        if (name.Length == 0) { _error = "简历名称不能为空。"; Render(); return; }
        _saving = true; _error = null; _notice = null;
        Render();
        var body = new JsonObject { ["base_lock_version"] = S.Clone(record.Get("lock_version")) ?? JsonValue.Create(1) };
        if (!S.Same(_doc, _saved)) body["data"] = ResumeDocument.PrepareForSave(_doc, _saved);
        if (!S.Same(_style, _savedStyle)) body["style"] = S.Clone(_style);
        if (name != record.Text("title")) body["title"] = name;
        // 请求发出时的内容：保存期间继续编辑的部分留给下一次
        var pending = (S.Clone(_doc), S.Clone(_style), _title);
        try
        {
            var result = await Api.CareerRequestAsync($"/api/resumes/{_resumeId}", "PUT", body: body);
            if (result.Get("resume") is not { } resume) throw new InvalidDataException();
            _saving = false;
            ApplySaved(resume, pending);
            _saveFailed = false; _notice = null;
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (error is ApiException { Status: System.Net.HttpStatusCode.Conflict, Code: "RESUME_EDIT_CONFLICT" }) _conflict = true;
            _error = ResumeDocument.SaveError(error);
            _saveFailed = true;
        }
        finally { _saving = false; Render(); }
    }

    /// <summary>Web `applyTemplate`：随请求提交当前正文与名称；未保存的版式设置在新模板上重新套用，留待保存。</summary>
    async Task<string?> ApplyTemplate(ResumeTemplate template)
    {
        if (_record is not { } record || Busy) return null;
        PreviewTemplate(null);
        _saving = true; _error = null; _notice = null;
        Render();
        var pendingType = !S.Same(_style, _savedStyle) ? ResumeTypeSettings.Read(_style) : null;
        var body = new JsonObject { ["template_id"] = template.Id, ["base_lock_version"] = S.Clone(record.Get("lock_version")) ?? JsonValue.Create(1) };
        if (!S.Same(_doc, _saved)) body["data"] = ResumeDocument.PrepareForSave(_doc, _saved);
        var name = _title.Trim();
        if (name.Length > 0 && name != record.Text("title")) body["title"] = name;
        try
        {
            var result = await Api.CareerRequestAsync($"/api/resumes/{_resumeId}/apply-template", "POST", body: body);
            if (result.Get("resume") is not { } resume) throw new InvalidDataException();
            _saving = false;
            await Apply(resume);
            if (pendingType is not null) SetStyle(pendingType.Apply(_style));
            _notice = $"已切换为「{template.Name}」";
            return null;
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (error is ApiException { Status: System.Net.HttpStatusCode.Conflict, Code: "RESUME_EDIT_CONFLICT" }) _conflict = true;
            var message = ResumeDocument.SaveError(error);
            _error = message;
            return message;
        }
        finally { _saving = false; Render(); }
    }

    /// <summary>与后端 Content-Disposition 一致：保留中文标题，只替换文件系统不接受的字符（Mac `ResumesView.fileName`）。</summary>
    public static string FileName(string title)
    {
        var cleaned = new string(title.Select(c => "/:\\\0".Contains(c) ? '-' : c).ToArray()).Trim();
        return (cleaned.Length == 0 ? "resume" : cleaned) + ".pdf";
    }

    /// <summary>重绘时复用的部件先从旧父容器取下。</summary>
    internal static void Detach(FrameworkElement element)
    {
        switch (element.Parent)
        {
            case Panel panel: panel.Children.Remove(element); break;
            case Border border: border.Child = null; break;
            case ScrollViewer scroll: scroll.Content = null; break;
            case ContentControl content: content.Content = null; break;
        }
    }
}

/// <summary>编辑器里的 JSON 比较与 node_id（Swift `JSONValue ==` 与 `extension JSONValue { var nodeKey }`）。</summary>
static class EditorJson
{
    public static bool Same(JsonNode? a, JsonNode? b) => JsonNode.DeepEquals(a, b);
    public static JsonNode? Clone(JsonNode? node) => node?.DeepClone();
    public static List<JsonNode?> Arr(JsonNode? node) => node is JsonArray array ? array.ToList() : [];
    public static bool HasKey(JsonNode? node, string key) => node is JsonObject obj && obj.ContainsKey(key);
    /// <summary>列表标识：canonical 节点的 node_id。</summary>
    public static string NodeKey(this JsonNode? node) => node.Text("node_id");
}

/// <summary>`@AppStorage` 的对应物：未打包应用没有 ApplicationData，按键名存在本机应用数据目录的小文件里。</summary>
static class EditorPreferences
{
    static string PathFor(string key) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DrawOffer", "Preferences", key);

    public static string Read(string key, string fallback)
    {
        try { var value = File.ReadAllText(PathFor(key)).Trim(); return value.Length == 0 ? fallback : value; } catch { return fallback; }
    }

    public static void Write(string key, string value)
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(PathFor(key))!); File.WriteAllText(PathFor(key), value); } catch { }
    }
}

/// <summary>顶栏 32 / 28 的图标钮（Mac `HeadIconStyle`）：悬停 #f4f4f2 底、文字转 txt；禁用时 fnt2。</summary>
static class HeadIconStyle
{
    public static Border Make(string symbol, double size, double box, double radius, string label, Action action, bool enabled = true, FontWeightValue weight = default)
    {
        var icon = Icon(symbol, size, Sub);
        if (weight.Medium) icon.FontWeight = Medium;
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var button = new Border { Width = box, Height = box, CornerRadius = new CornerRadius(radius), Child = icon, Background = Brush(Clear) };
        var hover = false;
        void Paint()
        {
            icon.Foreground = Brush(!enabled ? Fnt2 : hover ? Txt : Sub);
            button.Background = Brush(enabled && hover ? Field : Clear);
        }
        button.OnHover(h => { hover = h; Paint(); });
        button.OnTap(action, label, () => enabled);
        ToolTipService.SetToolTip(button, label);
        Paint();
        return button;
    }

    public readonly record struct FontWeightValue(bool Medium);
}
