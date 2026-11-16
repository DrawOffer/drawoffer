using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using static DrawOffer.App.DesignSystem.V3;
using G = DrawOffer.Core.Models.ResumeGuideModel;
using S = DrawOffer.App.Views.Resumes.GuideJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 子视图（Swift 同文件的 `GuideMaterialsStep`、`SkillLevelsStep`、`CityChips`）。它们各自的 @State 放在一个状态对象里：
/// 视图在这次 Render 里没出现时丢掉，下次出现从头开始，与 SwiftUI 的生命周期一致。
/// </summary>
public sealed partial class ResumeGuidePanel
{
    bool _materialsUsed, _skillLevelsUsed, _citiesUsed;
    MaterialsState? _materialsView;
    SkillLevelsState? _skillLevelsView;
    string _cityInput = "";

    // MARK: 资料（01 / 02）

    sealed class MaterialsFile(string id, string name, string status, string? datasetId = null)
    {
        public string Id { get; } = id;
        public string Name { get; } = name;
        public string Status { get; set; } = status;
        public string? DatasetId { get; set; } = datasetId;
    }

    sealed class MaterialsState
    {
        public List<MaterialsFile> Files = [];
        public List<JsonNode>? Library;
        public bool Started;
        public string? ReadError;
        public bool Dropping;
        public string? FolderId;
    }

    /// <summary>资料一步：上传（PDF、Word、图片，存进“简历资料”资料夹）或从资料库里选，都处理完后交给引导一次读完。</summary>
    FrameworkElement MaterialsStep()
    {
        _materialsUsed = true;
        if (_materialsView is null)
        {
            _materialsView = new MaterialsState();
            _ = PreselectedAsync(_materialsView);
        }
        var state = _materialsView;
        var draft = Draft;
        int? found = draft is null ? null : G.FoundRows(draft).Count;
        var question = draft is null && !_running ? G.StepQuestion(_messages, "materials") : null;
        var reading = _running || state.Files.Any(f => f.Status is "uploading" or "reading");
        var done = found is not null && !reading;

        var list = new StackPanel { Margin = new Thickness(0, 24, 0, 0) };
        foreach (var file in state.Files)
        {
            var name = Sans(file.Name, 13.5, Txt, Medium);
            name.MaxLines = 1;
            var status = Sans(file.Status == "uploading" ? "上传中…" : file.Status == "failed" ? "没读出来，换一份试试"
                : file.Status == "reading" || _running ? "已存入资料库 · 正在读…" : "已存入资料库", 13, file.Status == "failed" ? Red : Fnt);
            var spinning = file.Status is "uploading" or "reading" || (_running && file.Status == "ready");
            var line = Spread(name, HStack(8, status, spinning ? new ProgressRing { IsActive = true, Width = 12, Height = 12 } : null));
            line.MinHeight = 50;
            list.Children.Add(VStack(0, line, Divider(Cl)));
        }
        list.Children.Add(LinkRow(state.Files.Count == 0 ? "上传文件" : "再加一份", "PDF、Word、图片　›", () => _ = PickAsync(state), reading));
        list.Children.Add(LinkRow("从资料库里选", state.Library is null ? "›" : "⌃", () => _ = ToggleLibraryAsync(state), reading));
        if (state.Library is { } library)
        {
            if (library.Count == 0)
                list.Children.Add(new Border { MinHeight = 44, Padding = new Thickness(16, 0, 0, 0), Child = Sans("资料库里还没有能读的文件", 13, Fnt).Align(HorizontalAlignment.Left, VerticalAlignment.Center) });
            foreach (var item in library)
            {
                var row = new Border { MinHeight = 44, Padding = new Thickness(16, 0, 0, 0), Child = Sans(item.Text("file_name"), 13.5, Txt).Align(HorizontalAlignment.Left, VerticalAlignment.Center) };
                list.Children.Add(Tap(row, () =>
                {
                    state.Library = null;
                    if (!state.Files.Any(f => f.DatasetId == item.Text("id")))
                    {
                        state.Started = false;
                        state.Files.Add(new MaterialsFile(item.Text("id"), item.Text("file_name"), "ready", item.Text("id")));
                    }
                    Render();
                }, item.Text("file_name")));
            }
        }
        // 05.1：快捷回答胶囊（编辑器里不用黑色按钮）
        var bottom = (done ? ResumeTalk.Chip(G.NextLabel("materials"), Next)
            : ResumeTalk.Chip(state.Files.Count == 0 ? "没有资料，一栏一栏填" : "不用资料了，一栏一栏填", Next, _running)).Also(c => c.HorizontalAlignment = HorizontalAlignment.Left).Top(22);

        var title = done ? $"读到了 {found ?? 0} 项" : reading ? "正在读资料" : question ?? "先给我一些资料吧";
        var note = done ? "后面每一步都会帮你填好，你只需要看一眼、改一改。" : "旧简历、成绩单、项目文档都行。读到的内容会帮你填好后面的每一项，上传的文件也会存进资料库。";
        var step = StepView("materials", title, note, thinking: reading, content: [list,
            state.ReadError is { } error ? Sans(error, 13.5, Red).Wrap().Top(8) : null, bottom]);

        // 拖入文件：虚线框提示（圆角 12、1.5 线宽、6 段长）
        var root = new Grid { AllowDrop = true, Background = Brush(Clear) };
        root.Children.Add(step);
        if (state.Dropping)
            root.Children.Add(new Rectangle
            {
                RadiusX = 12, RadiusY = 12, Stroke = Brush(Blue), StrokeThickness = 1.5,
                StrokeDashArray = [6 / 1.5, 6 / 1.5], IsHitTestVisible = false,
            });
        root.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            if (!state.Dropping) { state.Dropping = true; Render(); }
        };
        root.DragLeave += (_, _) => { if (state.Dropping) { state.Dropping = false; Render(); } };
        root.Drop += async (_, e) =>
        {
            state.Dropping = false;
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) { Render(); return; }
            var deferral = e.GetDeferral();
            var items = await e.DataView.GetStorageItemsAsync();
            deferral.Complete();
            await UploadAsync(state, items.OfType<StorageFile>().Select(f => f.Path).ToList());
        };
        ScheduleRead(state);
        return root;
    }

    /// <summary>首页带着资料进来：预选的资料直接列出来并开始读。</summary>
    async Task PreselectedAsync(MaterialsState state)
    {
        var ids = S.Strings(_guide.Get("dataset_ids"));
        if (ids.Count == 0 || state.Files.Count > 0) return;
        var datasets = (await TryGet("/api/datasets")).Get("datasets").Items();
        state.Files = ids.Select(id => new MaterialsFile(id, datasets.FirstOrDefault(d => d.Text("id") == id)?.Text("file_name") ?? "资料库里的资料", "ready", id)).ToList();
        Render();
    }

    async Task ToggleLibraryAsync(MaterialsState state)
    {
        if (state.Library is not null) { state.Library = null; Render(); return; }
        var datasets = (await TryGet("/api/datasets")).Get("datasets").Items();
        state.Library = datasets.Where(d => d.Text("parse_status") == "succeeded" && d.Text("asset_kind") is not ("audio" or "video")).Take(12).ToList();
        Render();
    }

    async Task PickAsync(MaterialsState state)
    {
        if (App.NativeWindow is not { } window) return;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var extension in new[] { "pdf", "docx", "md", "txt", "png", "jpg", "jpeg", "webp" }) picker.FileTypeFilter.Add("." + extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        var chosen = await picker.PickMultipleFilesAsync();
        if (chosen is null || chosen.Count == 0) return;
        await UploadAsync(state, chosen.Select(f => f.Path).ToList());
    }

    async Task<string> GuideFolderAsync(MaterialsState state)
    {
        if (state.FolderId is { } cached) return cached;
        var list = (await Api.CareerRequestAsync("/api/datasets/folders")).Get("folders").Items();
        var id = list.FirstOrDefault(f => f.Text("name") == G.FolderName)?.Text("id") ?? "";
        if (id.Length == 0)
            id = (await Api.CareerRequestAsync("/api/datasets/folders", "POST", body: new JsonObject { ["name"] = G.FolderName })).Text("id");
        state.FolderId = id;
        return id;
    }

    async Task UploadAsync(MaterialsState state, IReadOnlyList<string> paths)
    {
        state.Started = false;
        foreach (var path in paths.Take(Math.Max(0, 10 - state.Files.Count)))
        {
            var file = new MaterialsFile(Guid.NewGuid().ToString(), System.IO.Path.GetFileName(path), "uploading");
            state.Files.Add(file);
            Render();
            DatasetUpload? snapshot = null;
            try
            {
                var folder = await GuideFolderAsync(state);
                snapshot = await Task.Run(() => DatasetUpload.Snapshot(path, folder, 50L * 1024 * 1024));
                var record = await Api.UploadDatasetAsync(snapshot);
                file.Status = "reading";
                file.DatasetId = record.Text("id");
                Render();
                var ok = await WaitParsedAsync(record.Text("id"));
                file.Status = ok ? "ready" : "failed";
            }
            catch (Exception error)
            {
                ReportIfUnauthorized(error);
                file.Status = "failed";
            }
            finally { snapshot?.Discard(); }
            Render();
        }
    }

    static async Task<bool> WaitParsedAsync(string id)
    {
        for (var attempt = 0; attempt < 90; attempt++)
        {
            var datasets = (await TryGet("/api/datasets")).Get("datasets").Items();
            if (datasets.FirstOrDefault(d => d.Text("id") == id) is { } record)
            {
                var parse = record.Get("parse_status");
                if (record.Text("parse_status") == "succeeded" || (parse is null && record.Text("upload_status") == "succeeded")) return true;
                if (record.Text("parse_status") == "failed" || record.Text("upload_status") == "failed") return false;
            }
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        return false;
    }

    /// <summary>文件都处理完、至少有一份可读：停 1.2 秒后交给引导一次读完。</summary>
    void ScheduleRead(MaterialsState state)
    {
        if (state.Started || _running || state.Files.Count == 0 || state.Files.Any(f => f.Status is "uploading" or "reading")) return;
        var ids = S.Strings(_guide.Get("dataset_ids")).Concat(state.Files.Where(f => f.Status == "ready").Select(f => f.DatasetId).OfType<string>()).Distinct().ToList();
        if (ids.Count == 0) return;
        state.Started = true;
        _ = ReadLater();
        async Task ReadLater()
        {
            await Task.Delay(1200);
            state.ReadError = null;
            try
            {
                await ChangeAsync("set_materials", datasets: ids);
                await SendAsync(G.Kickoff, kickoff: true);
            }
            catch
            {
                state.Started = false;
                state.ReadError = "资料没交给引导，稍后再试。";
                Render();
            }
        }
    }

    // MARK: 技能（06）

    sealed class SkillLevelsState { public bool Adding; public string More = ""; }

    FrameworkElement SkillLevelsStep()
    {
        _skillLevelsUsed = true;
        var state = _skillLevelsView ??= new SkillLevelsState();
        var skills = _skills ?? [];
        var body = new StackPanel();
        if (skills.Count > 0)
        {
            var rows = new StackPanel { Margin = new Thickness(0, 24, 0, 0) };
            for (var index = 0; index < skills.Count; index++)
            {
                var position = index;
                var skill = skills[index];
                var name = Sans(skill.Name, 13.5, Txt).Frame(width: 120);
                name.MaxLines = 1;
                var levels = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18 };
                foreach (var level in G.SkillLevels)
                {
                    var selected = skill.Level == level.Key;
                    levels.Children.Add(Tap(Sans(level.Label, 13.5, selected ? Txt : Fnt2, selected ? Semibold : Regular),
                        () => { _skills![position] = (skill.Name, level.Key); Render(); }, level.Label));
                }
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(levels, $"{skill.Name} 的熟练度");
                var remove = Tap(new Border { Width = 24, Height = 24, Child = Icon("xmark", 11, Fnt2) },
                    () => { _skills!.RemoveAt(position); Render(); }, $"去掉 {skill.Name}");
                var line = Columns(12, (Px(120), name), (Auto, levels), (Star(), new Border()), (Auto, remove));
                line.MinHeight = 50;
                foreach (var child in line.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
                rows.Children.Add(VStack(0, line, Divider(Cl)));
            }
            body.Children.Add(rows);
        }
        if (state.Adding || skills.Count == 0)
            body.Children.Add(Underline("比如“Python、Linux”，回车添加", () => state.More, v => state.More = v, _busy, text =>
            {
                var current = _skills ?? [];
                var known = current.Select(s => s.Name.ToLowerInvariant()).ToHashSet();
                var added = G.SplitSkillNames(text).Where(x => !known.Contains(x.ToLowerInvariant())).Select(x => (x, "familiar"));
                _skills = current.Concat(added).Take(30).ToList();
            }));
        else
            body.Children.Add(Tap(Sans("＋ 添加技能", 13, Blue), () => { state.Adding = true; Render(); }, "＋ 添加技能").Top(16));
        body.Children.Add(Actions(skills.Count == 0 ? TextLink("先跳过", Skip) : null, "写进简历", () => _busy || (_skills ?? []).Count == 0, () => WriteSkills(null)));
        return StepView("skills", skills.Count == 0 ? "你会哪些技能？" : "这些技能，你分别到什么程度？",
            skills.Count == 0 ? "直接写，用顿号隔开；写完再选熟练程度。" : "选好后，我会按方向把每项展开成具体知识点写进左边，程度照你选的写。",
            back: Back, content: body);
    }

    // MARK: 城市

    /// <summary>城市：回车或逗号添加，退格删掉最后一个；最多 5 个，每个最多 20 字。</summary>
    FrameworkElement CityChips(List<string> cities, Action<List<string>> set)
    {
        _citiesUsed = true;
        var flow = new VariableSizedFlow(16);
        foreach (var city in cities)
        {
            var remove = Tap(Icon("xmark", 9, Txt), () => { set(cities.Where(c => c != city).ToList()); Render(); }, $"去掉 {city}");
            flow.Add(HStack(4, Sans(city, 13.5, Txt), remove));
        }
        var box = PlainBox("输入城市，回车添加", _cityInput, "城市");
        box.MinWidth = 120;
        box.MaxLength = 21; // 多留一位给结尾的逗号
        void Add()
        {
            var value = _cityInput.Trim();
            if (value.Length > 0 && !cities.Contains(value)) set(cities.Append(value).Take(5).ToList());
            _cityInput = "";
            Render();
        }
        box.TextChanged += (_, _) =>
        {
            var value = box.Text;
            if (value.EndsWith('，') || value.EndsWith(',')) { _cityInput = value[..^1]; Add(); return; }
            if (S.Count(value) > 20) { box.Text = S.Prefix(value, 20); box.SelectionStart = box.Text.Length; return; }
            _cityInput = value;
        };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Add(); }
            else if (e.Key == Windows.System.VirtualKey.Back && box.Text.Length == 0 && cities.Count > 0)
            {
                e.Handled = true;
                set(cities.Take(cities.Count - 1).ToList());
                Render();
            }
        };
        flow.Add(box);
        return flow.Panel.Pad(0, 12, 0, 12);
    }
}
