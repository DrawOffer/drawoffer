using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

public sealed partial class MockHomeView
{
    void ShowLegend() => V3Overlay.Show(XamlRoot, close => V3Dialog.Make(VStack(18, V3DialogHead.Make("图上的记号"),
        Sans("蓝色 · 到了目标线", 13, Blue), Sans("橙色 · 还没到，短线是还差几层", 13, Orange),
        Sans("虚线点 · 还没被问过，橙色是岗位要求里有", 13, Sub), Sans("点越大，越可能被问", 13, Sub),
        Sans("目标线 · 这一档难度要答进的那一圈", 13, Blue), Sans("一场练习的路线 · × 是那层没答上", 13, Sub),
        Sans("地平线 · 练过的分数 → 今天 → 面试", 13, Sub)), [new V3Button("知道了", close)], close));
    void ShowJobs()
    {
        V3Overlay.Show(XamlRoot, close =>
        {
            var search = new V3SearchField("搜公司或岗位", width: null); var list = VStack(8);
            void Draw(string query)
            {
                list.Children.Clear();
                foreach (var app in _applications.Where(x => x.Text("status") == "active" && x.Get("archived_at") is null && ($"{x.Text("company_name_snapshot")} {x.Text("job_title_snapshot")}").Contains(query, StringComparison.OrdinalIgnoreCase)))
                {
                    var usable = app.Get("job_description_id") is not null;
                    list.Children.Add(new V3Button($"{app.Text("company_name_snapshot")} · {app.Text("job_title_snapshot")}\n{(usable ? "JD 已上传" : "还没有 JD · 去补 ›")}", () => { close(); if (usable) _ = ChangeTarget(app.Display("id")); else _jobs(); }, V3Button.Kind.Ghost, 56, fill: true));
                }
                if (list.Children.Count == 0) list.Children.Add(Sans("没有匹配的岗位", 12, Fnt));
            }
            search.Changed += query => Draw(query); Draw("");
            return V3Dialog.Make(VStack(16, V3DialogHead.Make("从岗位看板选岗位", "面试官按这个岗位的 JD 出题。"), search,
                new ScrollViewer { Content = list, MaxHeight = 300 }, new V3Button("不挑岗位 · 只按简历出题", () => { close(); _ = ChangeTarget("general"); })),
                [new V3Button("去岗位看板添加新岗位 ›", () => { close(); _jobs(); }, V3Button.Kind.Text), new V3Button("取消", close)], close, 464);
        });
    }
    bool _settingsOpen;
    void ShowSettings() { _settingsOpen = !_settingsOpen; Render(); }
    FrameworkElement SettingsPanel()
    {
            void close() { _settingsOpen = false; Render(); }
            var body = VStack(14, Spread(Sans("面试设置", 14, Txt, Bold), new V3Button("恢复推荐", () => { _typeTouched = _focusTouched = _resumeTouched = false; _difficulty = "intermediate"; _mode = _speech ? "voice" : "text"; _count = 8; ApplyDefaults(); Render(); }, V3Button.Kind.Text, small: true)));
            var resumes = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, PlaceholderText = "选择简历" };
            foreach (var resume in _resumesData.Take(8)) resumes.Items.Add(new ComboBoxItem { Content = resume.Text("title"), Tag = resume.Display("id") });
            resumes.SelectedItem = resumes.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == _resume);
            resumes.SelectionChanged += (_, _) => { if (resumes.SelectedItem is ComboBoxItem item) { _resume = (string)item.Tag; _resumeTouched = true; _ = RefreshMatch(); } };
            body.Children.Add(VStack(6, Sans("简历", 13, Sub), resumes));
            if (_resumesData.Count == 0) body.Children.Add(new V3Button("去「我的简历」导入或新建 ›", () => { close(); _resumes(); }, V3Button.Kind.Text));
            body.Children.Add(Spread(Sans("岗位 JD", 13, Sub), new V3Button(Target.Kind == MockMap.TargetKind.General ? "不带岗位 JD ⌄" : $"带入 {MockMap.CompanyName(Target)} ⌄", () => { close(); ShowJobs(); }, V3Button.Kind.Text)));
            var types = new V3Segmented<string>(MockMap.TypeNames.Select(x => (x.Key, x.Value)), _type, height: 30, fontSize: 12);
            types.Changed += type => { _type = type; _typeTouched = true; ApplyDefaults(); Render(); }; body.Children.Add(VStack(6, Sans("类型", 13, Sub), types));
            var difficulty = new V3Segmented<string>(MockMap.DiffName.Select(x => (x.Key, x.Value)), _difficulty, height: 30, fontSize: 12);
            difficulty.Changed += value => { _difficulty = value; ApplyDefaults(); Render(); }; body.Children.Add(Spread(Sans("难度", 13, Sub), difficulty));
            var mode = new V3Segmented<string>(_speech ? [("text", "文字"), ("voice", "语音")] : [("text", "文字")], _mode, height: 30, fontSize: 12);
            mode.Changed += value => { _mode = value; Render(); }; body.Children.Add(Spread(Sans("作答", 13, Sub), mode));
            if (!_speech) body.Children.Add(Sans("语音服务暂不可用，使用文字作答", 11, Fnt));
            var count = new V3Segmented<int>(new[] { 5, 8, 10 }.Select(x => (x, x.ToString())), _count, height: 30, fontSize: 12);
            count.Changed += value => { _count = value; Render(); }; body.Children.Add(Spread(Sans("题数", 13, Sub), count));
            var focused = Home.Points.FirstOrDefault(x => x.Point.Id == _focus);
            body.Children.Add(Sans(focused is null ? "让面试官决定先问哪一处 · 点图上的知识点可以换" : $"先问「{focused.Point.Name}」", 12, focused is null ? Fnt : Orange).Wrap());
            var credits = MockMap.Credits(_prices.FirstOrDefault(x => x.Text("featureCode") == "mock_interview"), _mode == "voice" ? _prices.FirstOrDefault(x => x.Text("featureCode") == "mock_interview_voice") : null, _count);
            body.Children.Add(Sans($"约 {_count * 5} 分钟{(credits is null ? "" : " · " + credits)}", 11.5, Fnt));
            body.Children.Add(Spread(new V3Button("更多设置 ›", () => { close(); ShowMore(); }, V3Button.Kind.Text, small: true), new V3Button("完成", close, V3Button.Kind.Text, small: true)));
            body.Width = 324;
            return Card(body, 12, new Thickness(18, 16, 18, 14), White, Hex(0xE6E3DC));
    }
    async Task RefreshMatch()
    {
        var generation = ++_generation; var job = Target.Kind == MockMap.TargetKind.General ? "" : Target.Application.Display("job_description_id");
        try { var match = job.Length > 0 ? await Optional("/api/memory/match-evidence", new() { ["job_id"] = job, ["resume_id"] = _resume }) : null; if (_life.Alive && generation == _generation) { _match = match; ApplyDefaults(); Render(); } } catch (OperationCanceledException) { }
    }
    void ShowMore() => V3Overlay.Show(XamlRoot, close =>
    {
        var language = new V3Segmented<string>([("zh", "中文"), ("en", "英文")], _language, height: 30, fontSize: 12); var lang = _language; language.Changed += value => lang = value;
        var follow = new ToggleSwitch { IsOn = _follow, OnContent = "", OffContent = "" }.Tip("允许追问");
        var materials = new ToggleSwitch { IsOn = _materials && LibraryDocs.Count > 0, IsEnabled = LibraryDocs.Count > 0, OnContent = "", OffContent = "" }.Tip("评分时参考资料库");
        return V3Dialog.Make(VStack(22, V3DialogHead.Make("更多设置"), Spread(VStack(4, Sans("面试语言", 14), Sans("面试官提问和报告使用的语言", 12, Fnt)), language),
            Spread(VStack(4, Sans("允许追问", 14), Sans("每道主问题最多追问 2 次，关掉就一题一答", 12, Fnt).Wrap()), follow),
            Spread(VStack(4, Sans("评分时参考资料库", 14), Sans($"{LibraryDocs.Count} 份文档 · 只用于评分，不参与出题", 12, Fnt).Wrap(), new V3Button("去资料库 ›", () => { close(); _library(); }, V3Button.Kind.Text)), materials)),
            [new V3Button("取消", close), new V3Button("保存", () => { _language = lang; _follow = follow.IsOn; _materials = materials.IsOn; close(); Render(); }, V3Button.Kind.Dark)], close, 464);
    });
}
