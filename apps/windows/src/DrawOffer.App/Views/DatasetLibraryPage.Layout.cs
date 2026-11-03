using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

public sealed partial class DatasetLibraryPage
{
    void Home()
    {
        var keyword = _query.Trim();
        if (_tab == "jobs")
        {
            if (_jobState != "ready") { _results.Children.Add(Stack(T(_jobState == "failed" ? "求职进程加载失败" : "正在加载求职进程…", 17), B("重新加载", () => _ = LoadJobs())).Top(72)); return; }
            if (Listed.Count == 0) { _results.Children.Add(Blank("还没有放了资料的求职进程", ["在求职进度里给某一轮上传录音、笔记或文件后，", "这条投递会出现在这里，按轮次整理好。"], true, B("打开投递看板", () => DrawOffer.App.Shell.WorkspaceShell.Current.Select(WorkspaceSection.Jobs)))); return; }
            var projects = Listed.Where(x => x.Name.Contains(keyword, StringComparison.OrdinalIgnoreCase)).ToList();
            if (projects.Count == 0) _results.Children.Add(T("没有匹配的项目。", 13, true).Top(40));
            else _results.Children.Add(ProjectGrid(projects.Select(JobCard).ToList(), false));
            return;
        }
        var folders = _folders.OrderByDescending(x => Math.Max(JobProjects.Time(S(x, "updated_at")), _files.Where(f => f.Folder == S(x, "id")).Select(f => JobProjects.Time(f.Text("created_at"))).DefaultIfEmpty(0).Max())).Where(x => S(x, "name").Contains(keyword, StringComparison.OrdinalIgnoreCase)).ToList();
        if (keyword.Length > 0 && folders.Count == 0) { _results.Children.Add(T("没有匹配的项目。", 13, true).Top(40)); return; }
        if (_folders.Count == 0)
        {
            var chips = new List<UIElement> { T("从常用的开始", 12, true) };
            foreach (var name in new[] { "秋招简历打磨", "面试题库", "证书与成绩单" }) chips.Add(B(name, () => _ = Rename("create", new JsonObject { ["name"] = name })));
            _results.Children.Add(Blank("还没有自己的项目", ["按一件事把资料放在一起，比如一次秋招、一门复习或一套证书。", "在求职进度里上传的录音和笔记，会自动归到「求职进程」。"], false, chips.ToArray())); return;
        }
        var cards = folders.Select(FolderCard).ToList();
        if (keyword.Length == 0)
        {
            var content = VStack(10, T("＋", 20).Align(HorizontalAlignment.Center), T("新建项目", 13).Align(HorizontalAlignment.Center), T("把同一件事的资料放在一起", 11, true).Align(HorizontalAlignment.Center));
            var create = Click(content, () => _ = Rename("create"));
            create.BorderThickness = new Thickness(0);
            var dashed = new Rectangle { RadiusX = 16, RadiusY = 16, Stroke = Brush(Fnt2), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 4, 3 }, IsHitTestVisible = false };
            cards.Add(Layer(create, dashed));
        }
        _results.Children.Add(ProjectGrid(cards));
    }
    Grid ProjectGrid(List<FrameworkElement> cards, bool aspect = true)
    {
        var grid = new Grid { ColumnSpacing = 20, RowSpacing = 20, Margin = new Thickness(0, 18, 0, 0) };
        void Layout(double width)
        {
            var columns = Math.Max(1, (int)((width + 20) / 293)); var cellWidth = Math.Max(0, (width - (columns - 1) * 20) / columns);
            grid.Children.Clear(); grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
            for (var i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new());
            for (var i = 0; i < (cards.Count + columns - 1) / columns; i++) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            for (var i = 0; i < cards.Count; i++) { var card = cards[i]; if (aspect) card.Height = cellWidth * 172 / 273; Grid.SetColumn(card, i % columns); Grid.SetRow(card, i / columns); grid.Children.Add(card); }
        }
        grid.SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > .5) Layout(e.NewSize.Width); };
        Layout(Math.Max(273, ActualWidth - V3Page.Gutter(ActualWidth) * 2)); return grid;
    }
    static Button Click(UIElement content, Action action)
    {
        var button = new Button { Content = content, Background = Brush(Clear), Foreground = Brush(Txt), Padding = new Thickness(0), BorderThickness = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch };
        button.Template = (ControlTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'><ContentPresenter Content='{TemplateBinding Content}' HorizontalContentAlignment='Stretch' VerticalContentAlignment='Stretch'/></ControlTemplate>");
        button.Click += (_, _) => action(); return button;
    }
    FrameworkElement FolderCard(JsonNode folder)
    {
        var records = _files.Where(x => x.Folder == S(folder, "id")).OrderByDescending(x => x.Text("created_at")).ToList();
        var count = (int)(folder.Number("dataset_count") ?? records.Count);
        var stage = new Canvas { Width = 257, Height = 96, Background = Brush(Stage) };
        var shown = records.Take(3).ToArray(); var n = shown.Length == 0 ? 2 : shown.Length;
        for (var i = 0; i < n; i++)
        {
            var sample = shown.Length == 0 ? null : shown[i]; var sheet = Paper(sample); var x = n == 1 ? 98 : n == 2 ? 79 + i * 40 : 59 + i * 40; var y = n == 1 ? 16 : n == 2 ? 19 : i == 1 ? 16 : 22;
            sheet.RenderTransform = new RotateTransform { Angle = n == 1 ? 0 : n == 2 ? i == 0 ? -4 : 4 : (i - 1) * 7, CenterX = 30, CenterY = 39 }; Put(stage, sheet, x, y);
        }
        var body = new Grid(); body.RowDefinitions.Add(new()); body.RowDefinitions.Add(new() { Height = new GridLength(67) });
        body.Children.Add(new Border { Child = new Viewbox { Child = stage, Stretch = Stretch.Uniform }, Background = Brush(Stage), CornerRadius = new CornerRadius(11), Margin = new Thickness(7, 7, 7, 7) });
        var label = VStack(4, T(S(folder, "name"), 14).Wrap(1), T(count == 0 ? "还没有资料" : $"{count} 份资料" + (records.Count > 0 ? " · 最近上传 " + Relative(records[0].Text("created_at")) : ""), 12, true).Wrap(1)); label.Margin = new(17, 7, 34, 0); Grid.SetRow(label, 1); body.Children.Add(label);
        var button = Click(body, () => Navigate(S(folder, "id"))); button.IsEnabled = !_busy; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "打开项目「" + S(folder, "name") + "」");
        var card = V3.Card(button, 16, new Thickness(0)); card.Elevate(4); var root = Layer(card);
        var menu = new MenuFlyout(); var rename = new MenuFlyoutItem { Text = "重命名" }; rename.Click += (_, _) => _ = Rename("folder", folder); menu.Items.Add(rename); var delete = new MenuFlyoutItem { Text = "删除项目及资料" }; delete.Click += (_, _) => _ = DeleteFolder(folder); menu.Items.Add(delete);
        var more = new Button { Content = "•••", Flyout = menu, Padding = new Thickness(0), Width = 24, Height = 24, Background = Brush(Clear), BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 12, 30), IsEnabled = !_busy }; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, "项目「" + S(folder, "name") + "」操作菜单"); root.Children.Add(more); return root;
    }
    static void Put(Canvas canvas, FrameworkElement element, double x, double y) { Canvas.SetLeft(element, x); Canvas.SetTop(element, y); canvas.Children.Add(element); }
    static (string Label, Color Color, Color Tint) Tone(DatasetRecord item)
    {
        var label = item.Format.Length == 0 ? "FILE" : item.Format[..Math.Min(4, item.Format.Length)];
        return item.Media ? (label, Orange, Hex(0xFBF1E6)) : label switch { "PDF" => (label, Red, Hex(0xFBEEEE)), "MD" => (label, Green, Hex(0xECF5EF)), "DOCX" => (label, Blue, Hex(0xEDF2FC)), _ => (label, Sub, Field) };
    }
    static Border FormatIcon(DatasetRecord item) { var tone = Tone(item); return Fill(tone.Tint, 8, 32, 32, Sans(tone.Label, tone.Label.Length > 3 ? 7 : 8, tone.Color, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center)); }
    static FrameworkElement Paper(DatasetRecord? item, bool mini = false)
    {
        var canvas = new Canvas { Width = mini ? 62 : 60, Height = mini ? 80 : 78 };
        canvas.Children.Add(V3.Card(null, mini ? 5 : 4, new Thickness(0), item is null ? Alpha(White, .72) : White).Frame(canvas.Width, canvas.Height));
        if (mini)
        {
            Put(canvas, Fill(Fnt2, 2, 34, 4), 7, 9);
            Put(canvas, Fill(V3.Line, 2, 43, 3), 7, 18); Put(canvas, Fill(V3.Line, 2, 31, 3), 7, 25);
            if (item is not null) { var label = item.Format; Put(canvas, Fill(label == "PDF" ? Orange : Blue, 3, label.Length * 5 + 14, 13, Number(label, 7.5, White, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center)), 7, 60); }
            canvas.Elevate(6);
        }
        else
        {
            Put(canvas, Fill(item is null ? Alpha(Txt, .16) : Txt, 1, 25, 4), 8, 11);
            foreach (var (y, w) in new[] { (23, 43), (34, 43), (44, 43), (54, 24) }) Put(canvas, Fill(item is null ? Alpha(Txt, .07) : V3.Line, 1, w, 3), 8, y);
            if (item is not null) { var tone = Tone(item); Put(canvas, Fill(tone.Color, 3, tone.Label.Length * 5 + 8, 12, Sans(tone.Label, 7, White, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center)), 8, 55); }
        }
        return canvas;
    }
    FrameworkElement Blank(string title, string[] lines, bool audio = false, params UIElement[] actions)
    {
        var art = new Canvas { Width = 200, Height = 112, HorizontalAlignment = HorizontalAlignment.Center };
        for (var i = 0; i < 3; i++) { var paper = Paper(new DatasetRecord(new JsonObject { ["file_format"] = i == 1 ? "DOCX" : "PDF" }), true); paper.RenderTransform = new RotateTransform { Angle = i == 0 ? -8 : i == 2 ? 7 : 0, CenterX = 31, CenterY = 40 }; Put(art, paper, 18 + i * 52, i == 1 ? 12 : i == 2 ? 20 : 22); }
        if (audio) { var waveform = new Canvas { Width = 70, Height = 30 }; waveform.Children.Add(V3.Card(null, 8, new Thickness(0)).Frame(70, 30)); Put(waveform, Fill(Txt, 6, 12, 12), 8, 9); foreach (var (x, y, h) in new[] { (26,14,3), (31,10,9), (36,9,12), (41,10,10), (46,12,5), (51,13,4), (56,13,5) }) Put(waveform, Fill(Sub, 1, 2, h), x, y); waveform.Elevate(6); Put(art, waveform, 140, 76); }
        var stack = VStack(0, art, Sans(title, 17, Txt, Medium).Align(HorizontalAlignment.Center).Top(20)); var explanation = VStack(0); foreach (var line in lines) explanation.Children.Add(Sans(line, 13, Sub).Frame(height: 21).Align(HorizontalAlignment.Center)); stack.Children.Add(explanation.Top(8));
        stack.Children.Add(HStack(8, actions).Align(HorizontalAlignment.Center).Top(24)); stack.Margin = new(0, 72, 0, 40); return stack;
    }
    FrameworkElement JobCard(JobProjects.Project project)
    {
        var company = project.Application.Text("company_name_snapshot"); var role = project.Application.Text("job_title_snapshot");
        var title = VStack(2, Sans(company.NonEmpty() ?? project.Name, 14, Txt, Medium).Wrap(1), T(role, 12, true).Wrap(1));
        var head = HStack(10, Fill(Stage, 8, 32, 32, Serif(project.Monogram, 14, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center)), title);
        var chain = HStack(5); foreach (var node in project.Chain) { if (chain.Children.Count > 0) chain.Children.Add(T("›", 11, true)); chain.Children.Add(Sans(node?.Label ?? "…", 12, node?.State == JobProjects.State.Offer ? Blue : node?.Key == project.FocusKey ? Txt : Sub)); }
        var next = project.Next; var footer = Spread(T(next is null ? project.StatusLabel : "下一场 " + (CareerApplication.Date(next.Date ?? "")?.ToBeijing().ToString("MM-dd") ?? "") + " " + next.Label, 11.5, true).Wrap(1), T(project.MaterialSummary, 11.5, true), 12);
        var content = V3.Card(VStack(14, head, chain, footer), 14, new Thickness(17, 17, 17, 15), project.Archived ? Hex(0xFBFBFA) : White); content.Opacity = project.Archived ? .6 : 1; return Click(content, () => Navigate("app:" + project.Id));
    }
    static FrameworkElement AssociationArt(DatasetRecord item)
    {
        var art = new Canvas { Width = 240, Height = 96, HorizontalAlignment = HorizontalAlignment.Center };
        FrameworkElement Sheet(UIElement icon)
        {
            var sheet = new Canvas { Width = 76, Height = 52 };
            sheet.Children.Add(V3.Card(null, 8, new Thickness(0)).Frame(76, 52));
            Put(sheet, (FrameworkElement)icon, 10, 10); Put(sheet, Fill(Fnt2, 2, 26, 4), 40, 14); Put(sheet, Fill(V3.Line, 2, 20, 4), 40, 24); Put(sheet, Fill(V3.Line, 2, 56, 3), 10, 40); sheet.Elevate(6); return sheet;
        }
        var tone = Tone(item);
        Put(art, Sheet(Fill(tone.Tint, 6, 24, 24, Number(tone.Label, 7, tone.Color, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center))), 0, 22);
        art.Children.Add(new Microsoft.UI.Xaml.Shapes.Line { X1 = 82, X2 = 158, Y1 = 48, Y2 = 48, Stroke = Brush(Hex(0xB9B9B3)), StrokeThickness = 1.4, StrokeDashArray = new DoubleCollection { 3, 3 } });
        Put(art, V3.Card(Icon("link", 11, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), 12, new Thickness(0)).Frame(24, 24), 108, 36);
        Put(art, Sheet(Fill(Hex(0xEEF3FC), 6, 24, 24, Icon("calendar", 14, Blue).Align(HorizontalAlignment.Center, VerticalAlignment.Center))), 164, 22);
        return V3.Card(art, 11, new Thickness(0), Stage, Clear).Frame(height: 96);
    }
    FrameworkElement Description(JsonNode folder)
    {
        var text = S(folder, "description");
        return new Border { BorderBrush = Brush(Txt), BorderThickness = new Thickness(2, 0, 0, 0), Padding = new Thickness(12, 2, 0, 2), MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Left, Child = Spread(T(text.Length == 0 ? "还没有项目说明。写下这个项目是做什么的，方便以后回来时快速想起。" : text, 14, true).Wrap(), B(text.Length == 0 ? "添加说明" : "编辑说明", () => EditDescription(folder))) };
    }
    static string ListDate(string value) => CareerApplication.Date(value) is { } date ? date.ToBeijing().ToString(date.ToBeijing().Year == Beijing.Now.Year ? "MM-dd" : "yyyy-MM-dd") : value;
    static string Relative(string value) { if (CareerApplication.Date(value) is not { } date) return ""; var days = (Beijing.Now.Date - date.ToBeijing().Date).Days; return days == 0 ? "今天" : days == 1 ? "昨天" : date.ToBeijing().ToString(date.ToBeijing().Year == Beijing.Now.Year ? "MM-dd" : "yyyy-MM-dd"); }
    static (string Text, Color Color) Meta(DatasetRecord item)
    {
        if (item.Media) { var state = item.Text("parse_status") switch { "queued" => "等待转写", "processing" => "正在转写…", "failed" => "转写失败", _ => item.Raw.Bool("has_transcript") ? "转写完成" : "点击播放" }; return (item.Text("upload_status") == "failed" ? "上传失败" : item.Text("upload_status") == "uploading" ? "正在上传…" : item.Text("asset_kind") == "audio" ? "音频 · " + state : "视频 · 点击下载", Fnt); }
        if (item.Text("parse_status") == "failed" || item.Text("upload_status") == "failed") return ("解析失败" + (item.Text("failure_reason") switch { "format_unsupported" => " · 文件格式不受支持", "content_invalid" => " · 文件内容无效", "size_exceeded" => " · 文件内容超出解析限制", "service_unavailable" => " · 解析服务暂不可用", "timeout" => " · 解析超时", "quota_exceeded" => " · 当前资料数量已达上限", _ => "" }), Red);
        return item.Text("parse_status") == "queued" ? ("等待解析", Blue) : item.Busy ? ("正在解析…", Blue) : (item.Format switch { "MD" => "Markdown", "DOCX" => "Word", "TXT" => "纯文本", _ => item.Format }, Fnt);
    }
    void Files()
    {
        if (_folder != "files" && !_files.Any(x => x.Folder == _folder)) { _results.Children.Add(Blank("还没有资料", ["把与这个项目相关的文件直接拖到这里，", "或者从本地上传、从资料库里挑几份移进来。"], false, B("上传本地文件", () => _ = Pick()), B("从资料库选择", () => _ = PickExisting()))); return; }
        var table = new StackPanel { Spacing = 0, MinWidth = 760 }; var labels = Labels;
        var selectAll = new CheckBox { IsChecked = Visible.Any() && Visible.All(x => _selected.Contains(x.Id)), IsEnabled = !_busy && Visible.Any(), HorizontalAlignment = HorizontalAlignment.Right };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(selectAll, "全选当前列表");
        selectAll.Click += (_, _) => { foreach (var item in Visible) { if (selectAll.IsChecked == true) _selected.Add(item.Id); else _selected.Remove(item.Id); } Render(); };
        var header = Columns(0, (Star(), T("名称", 12, true)), (Px(190), T(_folder == "files" ? "所在项目" : "关联", 12, true)), (Px(66), T("大小", 12, true).Align(HorizontalAlignment.Right)), (Px(144), T("上传日期", 12, true).Align(HorizontalAlignment.Right)), (Px(42), _batch ? selectAll : new Border())); header.Padding = new(12, 22, 10, 0); header.Height = 46; table.Children.Add(header); table.Children.Add(Divider());
        foreach (var item in Visible)
        {
            var meta = Meta(item); var name = Click(HStack(12, FormatIcon(item), VStack(4, Sans(item.DisplayName, 14, Txt, Medium).Wrap(1).Tip(item.Name), Sans(meta.Text, 12, meta.Color).Wrap(1))), () => { if (_batch) { if (!_selected.Add(item.Id)) _selected.Remove(item.Id); Render(); } else _ = Open(item); });
            var location = _folder == "files" ? labels.GetValueOrDefault(item.Id, "未归入") : item.Text("interview_label").Length > 0 ? "面试 · " + item.Text("interview_label") : "";
            FrameworkElement date = Number(ListDate(item.Text("created_at")), 12, Sub).Align(HorizontalAlignment.Right, VerticalAlignment.Center);
            if (item.Retryable) date = B("重试", () => _ = Act(() => Request("/api/datasets/" + item.Id + "/retry", "POST")));
            FrameworkElement tail;
            if (_batch) { var check = new CheckBox { IsChecked = _selected.Contains(item.Id), IsEnabled = !_busy }; check.Click += (_, _) => { if (check.IsChecked == true) _selected.Add(item.Id); else _selected.Remove(item.Id); Render(); }; tail = check; }
            else { var menu = new MenuFlyout(); void Entry(string label, Action action, bool enabled = true) { var entry = new MenuFlyoutItem { Text = label, IsEnabled = enabled && !_busy }; entry.Click += (_, _) => action(); menu.Items.Add(entry); } Entry(item.Media ? "播放音视频" : "查看文件", () => _ = Open(item), item.Ready); Entry("下载原文件", () => _ = Download(item), item.Text("upload_status") == "succeeded"); Entry("重命名", () => _ = Rename("file", item.Raw)); Entry("移动到项目", () => { _selected.Clear(); _selected.Add(item.Id); _ = Move(); }); Entry("管理关联", () => _ = Associate(item), item.Text("upload_status") == "succeeded"); if (item.Retryable) Entry("重新解析", () => _ = Act(() => Request("/api/datasets/" + item.Id + "/retry", "POST"))); Entry("删除资料", () => { _selected.Clear(); _selected.Add(item.Id); _ = DeleteFiles(); }, !item.Busy); tail = new Button { Content = "•••", Flyout = menu, Background = Brush(Clear), BorderThickness = new Thickness(0), Padding = new Thickness(0), Width = 28, Height = 28 }; }
            var row = Columns(0, (Star(), name), (Px(190), T(location, 12, true).Wrap(1).Align(v: VerticalAlignment.Center)), (Px(66), Number(JobProjects.Size(item.Raw.Number("file_size") ?? 0), 12, Sub).Align(HorizontalAlignment.Right, VerticalAlignment.Center)), (Px(144), date), (Px(42), tail.Align(HorizontalAlignment.Right, VerticalAlignment.Center))); row.Height = 54; row.Padding = new(12, 0, 10, 0);
            var surface = V3.Card(row, 8, new Thickness(0), Clear, Clear); surface.PointerEntered += (_, _) => surface.Background = Brush(Hex(0xF6F6F3)); surface.PointerExited += (_, _) => surface.Background = Brush(Clear); surface.Margin = new Thickness(0, 5, 0, 0); var separator = Divider(); separator.Margin = new Thickness(68, 0, 0, 0);
            var lineIndex = table.Children.Count;
            if (lineIndex > 2) table.Children.Add(separator);
            surface.PointerEntered += (_, _) => { separator.Opacity = 0; if (table.Children.IndexOf(surface) + 1 < table.Children.Count && table.Children[table.Children.IndexOf(surface) + 1] is Border below) below.Opacity = 0; };
            surface.PointerExited += (_, _) => { separator.Opacity = 1; if (table.Children.IndexOf(surface) + 1 < table.Children.Count && table.Children[table.Children.IndexOf(surface) + 1] is Border below) below.Opacity = 1; };
            table.Children.Add(surface);
        }
        if (!Visible.Any()) table.Children.Add(T("没有匹配的资料。", 13, true).Top(40));
        if (DatasetRequest.Id(_folder))
        {
            var upload = Click(VStack(4, Sans("拖入文件，或点击上传到「" + Title + "」", 12.5, Sub, Medium).Align(HorizontalAlignment.Center), T($"PDF、DOCX、Markdown、TXT 最大 {JobProjects.Size(_limits.Number("max_file_bytes") ?? 20 * 1024 * 1024)}；音视频最大 {JobProjects.Size(MediaLimit)}", 10.5, true).Align(HorizontalAlignment.Center)).Align(v: VerticalAlignment.Center), () => _ = Pick());
            upload.IsEnabled = !_busy && !_batch && _loaded;
            table.Children.Add(Layer(upload, new Rectangle { RadiusX = 10, RadiusY = 10, Stroke = Brush(Fnt2), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 4, 3 }, IsHitTestVisible = false }).Frame(height: 52).Top(16));
        }
        _results.Children.Add(new ScrollViewer { Content = table, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    }
}
