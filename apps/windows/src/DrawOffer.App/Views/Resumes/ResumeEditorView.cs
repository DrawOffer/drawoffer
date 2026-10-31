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
/// 简历编辑（Mac `ResumeEditorView.swift`，Web `ResumeWorkbench` 的对应页）：纸面即编辑器，与 Web 同一套 TipTap 编辑器、分页、斜杠菜单与选区工具栏
/// （<see cref="ResumeEditorPaperView"/>）；顶栏、右侧工具轨与大纲 / 模板 / 排版 / 检查 / 引导面板由原生实现。
/// 保存提交 `PUT /api/resumes/{id}` 的 data、style 与 base_lock_version；冲突时提示重新载入，不覆盖他处的修改。
/// 侧栏的显隐由外壳负责（`WorkspaceShell.EditResume`），这里离开时只调用 close。
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
    ResumeCompleteness? _completeness;
    /// <summary>可编辑纸面：`paperSeed` 变化时重新载入（打开、换模板、重新载入）；版式在排版面板改动时按 `styleRevision` 下发。</summary>
    JsonNode? _paperSeed;
    int _paperGeneration, _styleRevision;
    /// <summary>纸面最近一次回报的版式：与它相同的变化来自纸面本身，不再下发。</summary>
    JsonNode? _paperStyle;
    readonly ResumeEditorChannel _channel = new();
    bool _canUndo, _canRedo;
    string _askIntent = "";
    bool _showOrder;
    double _zoom = 1.0;
    double? _zoomBadge;
    /// <summary>Web 存在 localStorage 的「页面排列」，只影响编辑时浏览方向（Mac `@AppStorage("workbench.pageArrangement")`）。</summary>
    string _pageArrangement = EditorPreferences.Read("workbench.pageArrangement", "vertical");
    // Mac 保留了 uploading（头像上传改由纸面完成后不再置位），这里同样保留以便 Busy 与 Swift 一致
    readonly bool _uploading = false;
    /// <summary>右侧工具轨当前打开的面板（Web 大纲 / 模板 / 排版 / 检查）。</summary>
    string? _panel;
    /// <summary>自动保存：停顿后串行保存；失败时显示横幅和重试。</summary>
    CancellationTokenSource? _autosaveTask;
    bool _saveFailed, _exporting;
    SectionFocus.Unit? _focusUnit;
    List<string> _importWarnings = [];
    /// <summary>这份简历的写作引导（Web：进入编辑器先读；没有引导时不显示入口，进行中时自动展开）。</summary>
    JsonNode? _guide;

    // 跨重绘保留的部件：纸面（光标与撤销历史）、标题框（焦点）、各面板（自身的加载与展开状态）
    ResumeEditorPaperView? _paper;
    int _paperBuilt = -1;
    readonly TextBox _titleBox = new();
    TemplateSwitchSheet? _templatePanel;
    OutlinePanel? _outlinePanel;
    CompletenessPanel? _checkPanel;
    TypeSettingsPanel? _typePanel;
    Grid? _typeGrid;
    ResumeGuidePanel? _guidePanel;
    V3Overlay? _focusSheet, _orderSheet, _leaveDialog;
    readonly Grid _root = new();
    // 重绘只换这些槽位之外的部件：纸面与标题框始终挂在同一个父容器上（换父会让 WebView2 重载、标题框失焦）
    readonly Grid _paperSlot = new();
    readonly Border _titleSlot = new();
    readonly Grid _chrome = new();
    int _zoomToken;

    bool Dirty => _record is not null && (!S.Same(_doc, _saved) || !S.Same(_style, _savedStyle) || _title != _record.Text("title"));
    List<JsonNode?> Sections => S.Arr(_doc.Get("sections"));
    string TemplateKey => _style.Get("template_snapshot").Text("template_key");
    bool Busy => _saving || _uploading;

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
        Unloaded += (_, _) => { _autosaveTask?.Cancel(); _paper?.Dispose(); _paper = null; };
    }

    // MARK: Body

    /// <summary>
    /// 状态变化后重画。外层结构只建一次（<see cref="BuildFrame"/>）：纸面槽位与标题框始终挂在同一个父容器上，
    /// 这里只替换顶栏两侧、导入提示、状态层与画布上的浮层。
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
        RenderSheets();
    }

    readonly Border _leftHost = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
    readonly Border _rightHost = new() { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    readonly Border _statusHost = new() { VerticalAlignment = VerticalAlignment.Center };
    readonly Border _banner = new();
    readonly Grid _state = new() { Background = Brush(Canvas) };
    readonly Grid _overlay = new();
    readonly Border _drawerHost = new() { Width = 380, VerticalAlignment = VerticalAlignment.Stretch, Background = Brush(V3.White), CornerRadius = new CornerRadius(14), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
    readonly Border _railHost = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly Border _guideHost = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Stretch };
    FrameworkElement? _drawerContent;

    void BuildFrame()
    {
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = Star() });
        // `.wb3-head`
        var center = HStack(14, _titleSlot, _statusHost);
        center.HorizontalAlignment = HorizontalAlignment.Center;
        center.MaxWidth = 560;
        var head = new Grid { Height = 56, Padding = new Thickness(16, 0, 16, 0), Background = Brush(V3.White) };
        head.Children.Add(_leftHost);
        head.Children.Add(_rightHost);
        head.Children.Add(center);
        _root.Children.Add(new Border { Child = head, Height = 57, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1), Background = Brush(V3.White), VerticalAlignment = VerticalAlignment.Top });
        Grid.SetRow(_banner, 1);
        _root.Children.Add(_banner);
        // 画布：纸面槽位 → 引导 → 抽屉与工具轨 → 保存失败卡与缩放提示 → 读取 / 失败状态层
        var area = new Grid { Background = Brush(Canvas) };
        area.Children.Add(_paperSlot);
        area.Children.Add(_guideHost);
        _drawerHost.Elevate(12);
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 15, 16, 16) };
        trailing.Children.Add(_drawerHost);
        trailing.Children.Add(_railHost);
        area.Children.Add(trailing);
        area.Children.Add(_overlay);
        area.Children.Add(_state);
        // `.has-guide`：纸面与引导当成一组居中，引导从画布 50% + 120 开始（>1280 宽）；1101–1280 贴右 380 宽
        area.SizeChanged += (_, e) => PlaceGuide(e.NewSize.Width);
        Grid.SetRow(area, 2);
        _root.Children.Add(area);
        _area = area;
    }

    Grid? _area;

    void PlaceGuide(double width)
    {
        var wide = width > 1280;
        _guideHost.Width = wide ? 440 : 380;
        _guideHost.Margin = new Thickness(wide ? width / 2 + 120 : width - 88 - 380, 15, 0, 0);
    }

    /// <summary>`.sheet(item:)` 与 `.sheet(isPresented:)`：聚焦这段、调整板块顺序。</summary>
    void RenderSheets()
    {
        if (XamlRoot is null) return;
        if (_focusUnit is { } unit && _focusSheet is not { IsOpen: true })
        {
            _focusSheet = V3Overlay.Show(XamlRoot, dismiss => new SectionFocusSheet(_resumeId, unit, _askIntent, adopt: (lineId, text) =>
            {
                if (SectionFocus.Replacing(_doc, lineId, text) is not { } next) return false;
                SetDoc(next);
                _channel.ReplaceData(next);
                Render();
                return true;
            }, close: dismiss), dismissed: () => { _focusUnit = null; _askIntent = ""; _focusSheet = null; });
        }
        if (_showOrder && _orderSheet is not { IsOpen: true })
        {
            _orderSheet = V3Overlay.Show(XamlRoot, dismiss => new SectionOrderSheet(Sections, ResumeLayout.Columns(_doc, _style),
                apply: order => _channel.Send(ResumeEditorCommand.Reorder(order.Select(x => x.NodeKey()))), close: dismiss),
                dismissed: () => { _showOrder = false; _orderSheet = null; });
        }
    }

    /// <summary>`.confirmationDialog("放弃未保存的修改？")`。</summary>
    void ConfirmLeave()
    {
        if (XamlRoot is null || _leaveDialog is { IsOpen: true }) return;
        _leaveDialog = V3Overlay.Show(XamlRoot, dismiss => V3Dialog.Make(V3DialogHead.Make("放弃未保存的修改？"),
            [new V3Button("继续编辑", dismiss, V3Button.Kind.Ghost), new V3Button("放弃修改", () => { dismiss(); _close(); }, V3Button.Kind.Danger)], dismiss, width: 400));
    }

    // MARK: Canvas

    /// <summary>
    /// `.workbench-canvas`：#f3f3f0 灰底；右侧工具卡片 56 宽（top 15 / right 16）浮在画布上，
    /// 面板卡片在它左边 12（right 84、top 15、bottom 16、380 宽）；面板打开时画布右侧让出 464，否则 72。
    /// </summary>
    static readonly Color Canvas = Hex(0xF3F3F0);
    bool DrawerOpen => _panel is not null && _panel != "guide";
    bool GuideOpen => _panel == "guide" && _guide is not null;
    double Trailing => GuideOpen ? 560 : DrawerOpen ? 464 : 72;

    void RenderCanvas()
    {
        // Mac 用 timingCurve(0.2, 0, 0, 1) 0.22 秒动画让出右侧；这里直接切换
        UpdatePreview();
        _paperSlot.Margin = new Thickness(0, 0, Trailing, 0);
        var ready = _record is not null;
        if (ready && GuideOpen && _guide is { } guide)
        {
            // SwiftUI 每次重绘都把最新的 guide 与正文传给引导面板；这里面板只建一次，之后用 Update 推送
            if (_guidePanel is not null) _guidePanel.Update(guide, _doc ?? new JsonObject());
            _guidePanel ??= new ResumeGuidePanel(_resumeId, guide, value => { _guide = value; Render(); }, _doc ?? new JsonObject(),
                _record.Get("template_id").String(), SaveBeforeWrite, resume => _ = Apply(resume),
                before => { SetDoc(before); _channel.ReplaceData(before); Render(); }, () => _ = ExportPdf(), () => { _panel = null; Render(); });
            if (_guideHost.Child != _guidePanel) { Detach(_guidePanel); _guideHost.Child = _guidePanel; }
            _guideHost.Visibility = Visibility.Visible;
            PlaceGuide(_area?.ActualWidth ?? 0);
        }
        else { _guideHost.Child = null; _guideHost.Visibility = Visibility.Collapsed; }
        var drawer = ready && DrawerOpen && !GuideOpen ? PanelView() : null;
        // 同一面板不重新挂载，保留它的滚动位置与输入焦点
        if (!ReferenceEquals(drawer, _drawerContent)) { if (drawer is not null) Detach(drawer); _drawerHost.Child = drawer; _drawerContent = drawer; }
        _drawerHost.Visibility = drawer is null ? Visibility.Collapsed : Visibility.Visible;
        _railHost.Child = ready ? ToolRail() : null;
        _overlay.Children.Clear();
        if (_saveFailed)
        {
            var notice = SaveNotice();
            notice.HorizontalAlignment = HorizontalAlignment.Center;
            notice.VerticalAlignment = VerticalAlignment.Top;
            notice.Margin = new Thickness(0, 15, Trailing, 0);
            _overlay.Children.Add(notice);
        }
        if (_zoomBadge is { } badge) _overlay.Children.Add(ZoomFeedback(badge));
        _overlay.IsHitTestVisible = _saveFailed;
    }

    // `.wb3-drawer`：380 宽、圆角 14、#e4e4e0 描边、白底、0 8 24 rgba(0,0,0,.08)（见 BuildFrame 的 _drawerHost）。

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

    // MARK: Toolbar & preview

    /// <summary>Web 顶栏的保存状态：编辑中 / 保存中 / 已保存 / 保存失败。</summary>
    (string text, Color color) SaveStatus()
    {
        if (_saving) return ("保存中…", Fnt);
        if (_saveFailed) return ("保存失败", Red);
        if (Dirty) return ("编辑中", Fnt);
        return ("已保存", Green);
    }

    /// <summary>
    /// `.wb3-head`：57 高（含 1px 下边线）、左右 16、三栏网格。左：32 圆角 8 的主页钮、13/500「简历编辑」、
    /// 1×16 分隔（左 20 右 6）、28×28 撤销/重做；中：14.5/500 居中标题（随内容伸缩，最宽 420）与保存状态；
    /// 右：32 高完整度胶囊（迷你仪表盘 + 分数 + 等级）与 104 宽「导出 PDF」。
    /// </summary>
    void RenderToolbar()
    {
        var home = HeadIconStyle.Make("house", 13, 32, 8, "返回全部简历", Leave);
        var undo = HeadIconStyle.Make("arrow.uturn.backward", 12, 28, 7, "撤销（Ctrl+Z）", () => _channel.Send(ResumeEditorCommand.Undo), enabled: _canUndo && !Busy);
        var redo = HeadIconStyle.Make("arrow.uturn.forward", 12, 28, 7, "重做（Ctrl+Y）", () => _channel.Send(ResumeEditorCommand.Redo), enabled: _canRedo && !Busy);
        var left = HStack(0,
            home,
            Sans("简历编辑", 13, Sub, Medium).Pad(8, 0, 0, 0),
            new Border { Width = 1, Height = 16, Background = Brush(Line), Margin = new Thickness(20, 0, 6, 0) },
            HStack(2, undo, redo));

        var right = new StackPanel { Orientation = Orientation.Horizontal };
        if (_conflict) right.Children.Add(new V3Button("重新载入", () => _ = Load(), V3Button.Kind.Ghost).Pad(0, 0, 8, 0));
        if (_completeness is { } completeness)
        {
            var on = _panel == "check";
            var pill = new Border
            {
                Child = HStack(0,
                    MiniGauge.Make(completeness.Score).Pad(0, 0, 7, 0),
                    Number($"{completeness.Score}", 12.5, Txt, Semibold),
                    Sans(completeness.Level, 11.5, Sub).Pad(6, 0, 0, 0)),
                Padding = new Thickness(10, 0, 14, 0), Height = 32, CornerRadius = Capsule(32),
                Background = Brush(on ? Field : V3.White), BorderBrush = Brush(on ? Hex(0xDCDCD8) : Cl), BorderThickness = new Thickness(1),
            };
            pill.OnTap(() => TogglePanel("check"), $"简历完整度 {completeness.Score} 分，{completeness.Level}，打开简历检查");
            if (on) AutomationProperties.SetItemStatus(pill, "已选中");
            right.Children.Add(pill);
        }
        var export = new V3Button(_exporting ? "导出中…" : "导出 PDF", () => _ = ExportPdf(), V3Button.Kind.Dark, height: 32, width: 104) { Enabled = !_exporting && _record is not null };
        right.Children.Add(export.Pad(8, 0, 0, 0));

        _leftHost.Child = left;
        _rightHost.Child = right;
        _statusHost.Child = SaveStatusView();
    }

    /// <summary>`WorkbenchSaveStatus`：已保存 绿色勾 / 编辑中 橙点 / 保存中… 转圈 / 保存失败 · 原因 红点；11.5px #6c6c65。</summary>
    StackPanel SaveStatusView()
    {
        UIElement mark;
        if (_saving) mark = new ProgressRing { IsActive = true, Width = 13, Height = 13, MinWidth = 0, MinHeight = 0 };
        else if (_saveFailed) mark = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = Brush(Red), Margin = new Thickness(3, 0, 3, 0) };
        else if (Dirty) mark = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = Brush(Orange), Margin = new Thickness(3, 0, 3, 0) };
        else mark = Icon("checkmark.circle", 11, Green);
        var text = _saving ? "保存中…" : _saveFailed ? $"保存失败 · {(_conflict ? "简历已在其他地方修改" : "请重试")}" : Dirty ? "编辑中" : "已保存";
        var label = Sans(text, 11.5, _saveFailed ? Red : Fnt);
        label.TextTrimming = TextTrimming.None;
        var row = HStack(5, mark, label);
        AutomationProperties.SetName(row, text);
        return row;
    }

    /// <summary>
    /// `.wb3-rail`：56 宽白卡、圆角 14、内边距 5/3、间距 2、0 6 20 rgba(0,0,0,.06)；每项 48×52、圆角 10、上 9，
    /// 18 号图标与 10.5px 文字间距 4，选中 #f4f4f2 底与 500 字重；「检查」右上 16 高橙色待完善数角标。
    /// </summary>
    Border ToolRail()
    {
        var items = VStack(2,
            RailButton("outline", "大纲", "list.bullet.indent"),
            RailButton("template", "模板", "rectangle.on.rectangle", label: "简历模板"),
            RailButton("type", "排版", "textformat", label: "排版"),
            RailButton("check", "检查", "checkmark.circle", label: "简历检查", badge: _completeness?.PendingCount ?? 0),
            _guide is not null ? RailButton("guide", "引导", "bubble.left", label: "引导创建简历") : null);
        var rail = new Border
        {
            Child = items, Padding = new Thickness(3, 5, 3, 5), Width = 56, Background = Brush(V3.White),
            CornerRadius = new CornerRadius(14), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        }.Elevate(10);
        AutomationProperties.SetName(rail, "编辑工具");
        return rail;
    }

    FrameworkElement RailButton(string key, string text, string symbol, string? label = null, int badge = 0)
    {
        var active = _panel == key;
        var enabled = !(key == "template" && (Busy || _conflict));
        var icon = Icon(symbol, 15, Sub).Frame(18, 18);
        var caption = Sans(text, 10.5, Sub, active ? Medium : Regular).Frame(height: 13);
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        var stack = VStack(4, icon, caption);
        stack.Margin = new Thickness(0, 9, 0, 0);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Top;
        var cell = new Grid { Width = 48, Height = 52, CornerRadius = new CornerRadius(10), Background = Brush(Clear) };
        cell.Children.Add(stack);
        if (badge > 0)
        {
            var count = new Border
            {
                Child = Number($"{badge}", 9.5, V3.White, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                Padding = new Thickness(4, 0, 4, 0), MinWidth = 16, MinHeight = 16, Height = 16, CornerRadius = Capsule(16), Background = Brush(Orange),
                HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(30, 4, 0, 0),
            };
            AutomationProperties.SetAccessibilityView(count, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            cell.Children.Add(count);
        }
        var hover = false;
        void Paint()
        {
            var ink = !enabled ? Fnt2 : active || hover ? Txt : Sub;
            icon.Foreground = Brush(ink);
            caption.Foreground = Brush(ink);
            cell.Background = Brush(active || (enabled && hover) ? Field : Clear);
        }
        cell.OnHover(h => { hover = h; Paint(); });
        cell.OnTap(() => TogglePanel(key), label ?? text, () => enabled);
        if (active) AutomationProperties.SetItemStatus(cell, "已选中");
        Paint();
        return cell;
    }

    FrameworkElement? PanelView()
    {
        switch (_panel)
        {
            case "outline":
                _outlinePanel ??= new OutlinePanel(SectionLabel,
                    jump: id => _channel.Send(ResumeEditorCommand.Jump(id == "identity" ? null : id)),
                    move: (from, to) => _channel.Send(ResumeEditorCommand.Reorder(S.Arr(_doc.Moving([new JsonPathPart.Key("sections")], from, to).Get("sections")).Select(x => x.NodeKey()))),
                    reorder: order => _channel.Send(ResumeEditorCommand.Reorder(order.Select(x => x.NodeKey()))),
                    rename: (index, value) => { if (index >= 0 && index < Sections.Count) _channel.Send(ResumeEditorCommand.Rename(Sections[index].NodeKey(), value)); },
                    remove: index => { if (index >= 0 && index < Sections.Count) _channel.Send(ResumeEditorCommand.Remove(Sections[index].NodeKey())); },
                    add: kind => _channel.Send(ResumeEditorCommand.Add(kind.key, kind.label)),
                    close: () => { _panel = null; Render(); });
                _outlinePanel.Update(Sections, _doc.Get("identity"), ResumeLayout.Columns(_doc, _style), _completeness?.FlaggedKinds ?? new HashSet<string>(), Busy);
                return _outlinePanel;
            case "type":
                if (_typeGrid is not null && (_typePanel is not null) == (ResumeTypeSettings.Read(_style) is not null))
                {
                    _typePanel?.Update(TypeSettings, _pageArrangement, Busy);
                    return _typeGrid;
                }
                var header = WorkbenchPanelHeader.Make("设置", null, "关闭排版面板", () => { _panel = null; Render(); });
                var grid = new Grid();
                _typeGrid = grid;
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
                grid.Children.Add(header);
                FrameworkElement body;
                if (ResumeTypeSettings.Read(_style) is not null)
                {
                    _typePanel ??= new TypeSettingsPanel(settings => { SetStyle(settings.Apply(_style)); Render(); },
                        arrangement => { _pageArrangement = arrangement; EditorPreferences.Write("workbench.pageArrangement", arrangement); _paper?.SetView(_zoom, arrangement == "horizontal"); Render(); });
                    _typePanel.Update(TypeSettings, _pageArrangement, Busy);
                    body = new ScrollViewer { Content = _typePanel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
                }
                else { _typePanel = null; body = Sans("当前模板不支持调整排版", 12.5, Fnt).Pad(24, 24, 24, 24); }
                Grid.SetRow(body, 1);
                grid.Children.Add(body);
                return grid;
            case "template":
                _templatePanel ??= new TemplateSwitchSheet(ApplyTemplate, () => { _panel = null; Render(); });
                _templatePanel.Update(TemplateKey, Busy || _conflict);
                return _templatePanel;
            case "check":
                if (_completeness is not { } result) return null;
                _checkPanel ??= new CompletenessPanel(() => { _panel = null; Render(); });
                _checkPanel.Update(result);
                return _checkPanel;
            default: return null;
        }
    }

    ResumeTypeSettings TypeSettings => ResumeTypeSettings.Read(_style) ?? new ResumeTypeSettings(ResumeTypeSettings.SerifStack, 10, 1.5, 16, 14, false);

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
        }
        // 纸面之上的提示条每次重画；纸面本身保持原位
        while (_paperSlot.Children.Count > 1) _paperSlot.Children.RemoveAt(1);
        if (_paperNote is { } note)
        {
            _paperSlot.Children.Add(new Border
            {
                Child = Sans(note, 11.5, Orange), Padding = new Thickness(8), Background = Brush(V3.White), CornerRadius = new CornerRadius(14),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 16),
            });
        }
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
                break;
            case ResumeEditorEvent.History history: _canUndo = history.CanUndo; _canRedo = history.CanRedo; break;
            case ResumeEditorEvent.Zoom zoom: SetZoom(zoom.Value, step: false); return;
            case ResumeEditorEvent.Key key:
                // 焦点在纸面里时快捷键先到页面：注入脚本把 Ctrl+= / Ctrl+- / Ctrl+0 转回原生
                if (key.Name == "=") SetZoom(_zoom + 0.1); else if (key.Name == "-") SetZoom(_zoom - 0.1); else if (key.Name == "0") SetZoom(1);
                return;
            case ResumeEditorEvent.Ask ask:
                if (FocusUnit(ask.UnitId) is not { } unit) { _paperNote = "这一行暂时不能聚焦修改"; break; }
                _askIntent = ask.Instruction;
                _focusUnit = unit;
                break;
            case ResumeEditorEvent.Error error: _paperNote = error.Message; break;
        }
        Render();
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
        ScheduleAutosave();
        _completeness = ResumeCompleteness.Evaluate(_doc) ?? _completeness;
    }

    void SetStyle(JsonNode? next)
    {
        if (S.Same(next, _style)) return;
        _style = next;
        // 排版面板改的版式下发给纸面；纸面自己回报的（头像尺寸）不再回送
        if (!S.Same(_style, _paperStyle)) { _styleRevision++; _paper?.UpdateStyle(_style, _styleRevision); }
        ScheduleAutosave();
    }

    /// <summary>`.workbench-title`：标题随内容伸缩（最宽 420、最窄 40），28 高、内边距 6、14.5/500 居中；悬停灰底，编辑时白底描边。</summary>
    void ConfigureTitle()
    {
        var box = _titleBox;
        box.FontFamily = SansFamily;
        box.FontSize = 14.5;
        box.FontWeight = Medium;
        box.Foreground = Brush(Txt);
        box.TextAlignment = TextAlignment.Center;
        box.Height = 28;
        box.MinHeight = 0;
        box.MinWidth = 0;
        box.Padding = new Thickness(6, 3, 6, 0);
        box.CornerRadius = new CornerRadius(7);
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
            Render();
        };
    }

    void FitTitle()
    {
        var probe = new TextBlock { Text = _titleBox.Text, FontFamily = SansFamily, FontSize = 14.5, FontWeight = Medium };
        probe.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        _titleBox.Width = Math.Min(420, Math.Max(40, probe.DesiredSize.Width + 14));
    }

    void SetTitle(string value)
    {
        _title = value;
        if (_titleBox.Text != value) _titleBox.Text = value;
        FitTitle();
    }

    /// <summary>
    /// 快捷键（Mac ⌘ → Ctrl）：Ctrl+Z / Ctrl+Y 撤销重做，Ctrl+= / Ctrl+- / Ctrl+0 缩放，Esc 关闭当前面板（`.onExitCommand`）。
    /// 焦点在纸面里时按键先到网页：撤销重做由 TipTap 自己处理，缩放由注入脚本转回（见 <see cref="ResumeEditorEvent.Key"/>）。
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
        Add(VirtualKey.Escape, VirtualKeyModifiers.None, () => { if (_panel is null) return false; _panel = null; Render(); return true; });
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
        var warnings = S.HasKey(resume.Get("import"), "warnings") ? resume.Get("import").Get("warnings") : resume.Get("import_warnings");
        _importWarnings = S.Arr(warnings).Select(x => x.String()).OfType<string>().ToList();
        _completeness = ResumeCompleteness.Evaluate(_saved);
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
        _completeness = ResumeCompleteness.Evaluate(_saved);
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
        }
        finally { _exporting = false; Render(); }
    }

    /// <summary>引导写入前：有未保存修改先保存；保存失败不写。</summary>
    async Task<bool> SaveBeforeWrite()
    {
        if (Dirty) { _autosaveTask?.Cancel(); await Save(); }
        return !Dirty;
    }

    /// <summary>Web `toggleGuide`：已结束的引导再次打开时请求重新开启；Esc 关闭当前面板。</summary>
    void TogglePanel(string key)
    {
        if (_panel == key) { _panel = null; Render(); return; }
        _panel = key;
        if (key != "guide") _guidePanel = null;
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

/// <summary>`WorkbenchGauge mini`（Mac `MiniGauge`）：18×16，半径 7、线宽 3 的 240° 圆弧，浅灰轨道 + 灰到黑渐变弧 + 末端白色旋钮。</summary>
static class MiniGauge
{
    public static FrameworkElement Make(int score) => WorkbenchGaugeShape.Make(score, mini: true);
}

/// <summary>Web `WorkbenchGauge`（Mac `WorkbenchGaugeShape`）：起点 150°、扫过 240°；大号半径 78、线宽 10，带每 5 分一格的刻度（20 的倍数与 40/70/90 加长）。</summary>
static class WorkbenchGaugeShape
{
    public static (double R, double Sw, double Width, double Height, double Cx, double Cy) GaugeGeometry(bool mini, double extra = 0)
    {
        double r = mini ? 7 : 78, sw = mini ? 3 : 10, pad = mini ? 2 : 18;
        double width = Math.Ceiling(2 * (r + pad)), cy = r + pad;
        return (r, sw, width, Math.Ceiling(cy + r * 0.5 + sw / 2 + 2 + extra), width / 2, cy);
    }

    public static FrameworkElement Make(int score, bool mini = false, double extra = 0)
    {
        var g = GaugeGeometry(mini, extra);
        var draw = new Draw(g.Width, g.Height);
        Point P(double angle, double radius) => new(g.Cx + radius * Math.Cos(angle * Math.PI / 180), g.Cy + radius * Math.Sin(angle * Math.PI / 180));
        Geometry Arc(double from, double to)
        {
            var figure = new PathFigure { StartPoint = P(from, g.R), IsClosed = false, IsFilled = false };
            figure.Segments.Add(new ArcSegment { Point = P(to, g.R), Size = new Size(g.R, g.R), SweepDirection = SweepDirection.Clockwise, IsLargeArc = to - from > 180 });
            return new PathGeometry { Figures = { figure } };
        }
        var end = 150 + 240 * Math.Max(0.5, Math.Min(100, (double)score)) / 100;
        draw.Stroke(Arc(150, 390), Hex(0xECECEA), g.Sw, round: true);
        draw.Stroke(Arc(150, end), Draw.Gradient(new Point(0, 0), new Point(g.Width, 0), (Hex(0xA3A39C), 0), (Hex(0x1D1D1B), 1)), g.Sw, round: true);
        if (!mini)
        {
            for (var index = 0; index <= 20; index++)
            {
                var value = index * 5;
                var angle = 150 + 240 * (double)value / 100;
                var level = value is 40 or 70 or 90;
                var major = value % 20 == 0 || level;
                var r1 = g.R + g.Sw / 2 + 5;
                draw.Stroke(Draw.Lines([P(angle, r1), P(angle, r1 + (major ? 6 : 3))]), Hex(level ? 0x96968Fu : major ? 0xC4C4BEu : 0xDCDCD8u), level ? 1.4 : 1, round: true);
            }
            var halo = g.Sw * 1.05;
            draw.Fill(Draw.Circle(P(end, g.R), halo), Alpha(Hex(0x1D1D1B), 0.08));
        }
        var knob = P(end, g.R);
        var kr = g.Sw * (mini ? 0.62 : 0.78);
        draw.Fill(Draw.Circle(knob, kr), V3.White);
        draw.Stroke(Draw.Circle(knob, kr), Hex(0x1D1D1B), g.Sw * (mini ? 0.34 : 0.3));
        AutomationProperties.SetAccessibilityView(draw.Surface, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return draw.Surface;
    }
}

/// <summary>`WorkbenchPanelHeader`：73 高（含 1px 下边线）、内边距 20/24；标题 16/500 行高 19、说明 11.5 行高 14、间距 6；右上 28 关闭钮（-4/-6）。</summary>
static class WorkbenchPanelHeader
{
    public static Border Make(string title, string? subtitle, string closeLabel, Action close)
    {
        var texts = VStack(6, Sans(title, 16, Txt, Medium).Frame(height: 19), subtitle is null ? null : Sans(subtitle, 11.5, Fnt).Frame(height: 14));
        texts.VerticalAlignment = VerticalAlignment.Top;
        var x = HeadIconStyle.Make("xmark", 12, 28, 7, closeLabel, close, weight: new(true));
        x.VerticalAlignment = VerticalAlignment.Top;
        x.Margin = new Thickness(0, -4, -6, 0);
        var row = Spread(texts, x, 8, VerticalAlignment.Top);
        row.Padding = new Thickness(24, 20, 24, 0);
        row.Height = 72;
        return new Border { Child = row, Height = 73, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 0, 0, 1) };
    }
}
