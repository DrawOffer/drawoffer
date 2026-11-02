using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerReviewReportView
{
    UIElement QuestionSection(List<JsonNode> questions, Dictionary<string, JsonNode> notes)
    {
        var index = Math.Min(_selected, questions.Count - 1);
        var question = questions[index];
        var stack = new StackPanel();
        stack.Children.Add(SectionTitle("逐题表现", $"期望深度 L{(questions.FirstOrDefault()?.Number("expected_depth") is { } depth ? (int)depth : 3)} · 点击题目查看完整问答与分析"));
        for (var offset = 0; offset < questions.Count; offset++)
        {
            if (offset > 0) stack.Children.Add(Divider(CareerPalette.Line));
            var item = questions[offset];
            var target = offset;
            var row = new Border { Child = QuestionRow(item, notes.ContainsKey(item.Text("key"))), CornerRadius = new CornerRadius(8), Background = Brush(offset == index ? CareerPalette.Soft : Clear) };
            stack.Children.Add(row.OnTap(() => { _selected = target; Render(); }, item.Text("question")));
        }
        stack.Children.Add(AnswerPanel(question, notes.GetValueOrDefault(question.Text("key"))).Top(12));
        return stack;
    }

    static FrameworkElement QuestionRow(JsonNode item, bool hasNote)
    {
        var score = item.Number("score");
        var tone = CareerReview.ScoreTone(score);
        var follow = item.Integer("follow_ups");
        var meta = string.Join(" · ", new[]
        {
            CareerReview.CategoryLabel(item.Text("category")), follow > 0 ? $"{follow} 次追问" : "无追问",
            item.Get("achieved_depth") is not null ? $"深度 L{item.Integer("achieved_depth")}" : null,
            item.Text("resume_conflict").Length == 0 ? null : "与简历不一致", hasNote ? "有笔记" : null,
        }.OfType<string>());
        var badge = new Border
        {
            Child = Mono(score is { } s ? $"{(int)Round(s)}" : "无法评估", score is null ? 10.5 : 12, tone == CareerTone.Gray ? CareerPalette.Sub : CareerPalette.Solid(tone), Semibold).Align(HorizontalAlignment.Center),
            MinWidth = 36 + 12, Padding = new Thickness(6, 2, 6, 2), CornerRadius = new CornerRadius(6), Background = Brush(CareerPalette.Background(tone)),
        };
        var number = Mono($"Q{item.Integer("index")}", 11, CareerPalette.Faint, Medium);
        var copy = VStack(2, Sans(item.Text("question"), 13, CareerPalette.Text, Medium).Wrap(), Sans(meta, 11, CareerPalette.Faint).Wrap());
        var row = Columns(14, (Px(24), number), (Star(), copy), (Auto, badge));
        foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        row.Padding = new Thickness(8, 14, 8, 14);
        return row;
    }

    FrameworkElement AnswerPanel(JsonNode question, JsonNode? note)
    {
        var number = question.Integer("index");
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(Sans($"AI 建议的回答 · Q{number}", 11, CareerPalette.Faint));
        stack.Children.Add(Sans(question.Text("question"), 15, CareerPalette.Text, Medium).Wrap());
        if (question.Text("answer").Length > 0) { stack.Children.Add(Heading("我的回答")); stack.Children.Add(Paragraph(question.Text("answer"))); }
        else stack.Children.Add(Sans(question.Text("answer_status") == "declined" ? "这道题没有作答" : "文字稿里没有找到这道题的回答，不计入得分", 12, CareerPalette.Faint).Wrap());
        var signals = question.Items("signals");
        if (signals.Count > 0)
        {
            stack.Children.Add(Heading("要点命中"));
            foreach (var signal in signals)
            {
                var verdict = signal.Text("verdict");
                var row = HStack(8, CareerChipView.Make(verdict == "hit" ? "命中" : verdict == "partial" ? "部分" : "未提到", verdict == "hit" ? CareerTone.Green : verdict == "partial" ? CareerTone.Orange : CareerTone.Gray),
                    Sans(signal.Text("signal"), 12.5, CareerPalette.Sub).Wrap(),
                    signal.Text("quote").Length > 0 ? Sans($"“{signal.Text("quote")}”", 12.5, CareerPalette.Faint).Wrap() : null);
                stack.Children.Add(row);
            }
        }
        if (question.Text("resume_conflict").Length > 0) stack.Children.Add(Banner(question.Text("resume_conflict"), true));
        var errors = question.Items("factual_errors");
        if (errors.Count > 0)
        {
            stack.Children.Add(Heading("事实错误"));
            foreach (var item in errors) stack.Children.Add(Sans("· " + (item.String() ?? ""), 12.5, CareerPalette.Sub).Wrap());
        }
        if (question.Text("strength").Length > 0) { stack.Children.Add(Heading("做得好的地方")); stack.Children.Add(Paragraph(question.Text("strength"))); }
        if (question.Text("improvement").Length > 0) { stack.Children.Add(Heading("可以更好")); stack.Children.Add(Paragraph(question.Text("improvement"))); }
        if (question.Text("suggested_answer").Length > 0) { stack.Children.Add(Heading("下次怎么答")); stack.Children.Add(Paragraph(question.Text("suggested_answer"))); }
        var snippets = question.Items("evidence_snippets");
        if (snippets.Count > 0)
        {
            stack.Children.Add(Heading("来自资料库的佐证"));
            foreach (var item in snippets)
                stack.Children.Add(new Border
                {
                    Child = VStack(2, Sans(item.Text("title"), 12, CareerPalette.Text, Medium), Sans(item.Text("text"), 12, CareerPalette.Sub).Wrap()),
                    Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(10), Background = Brush(CareerPalette.Soft),
                });
        }
        // 笔记编辑器按题目 key + 笔记 id + lock_version 复用（Mac `.id(...)`）：同一份笔记重绘不丢草稿
        var key = question.Text("key") + (note?.Text("id") ?? "") + $"{note?.Integer("lock_version") ?? 0}";
        if (!_notes.TryGetValue(key, out var editor))
        {
            var questionKey = question.Text("key");
            editor = new CareerQuestionNote(Session, question.Text("question"), note, Archived, saved => ReplaceNote(saved, questionKey));
            _notes[key] = editor;
        }
        stack.Children.Add(Detach(editor));
        stack.Children.Add(PrepActions(question));
        return new Border { Child = stack, Padding = new Thickness(20), CornerRadius = new CornerRadius(14), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1) };
    }

    static TextBlock Heading(string value) => Sans(value, 12.5, CareerPalette.Text, Medium).Top(4);
    static TextBlock Paragraph(string value) => Sans(value, 13, CareerPalette.Sub).Spaced(3).Wrap().Selectable();

    /// <summary>加入下一轮准备清单：把这道题复制进同一岗位之后一场待进行面试的清单。</summary>
    UIElement PrepActions(JsonNode question)
    {
        var row = HStack(8);
        if (_targets.Count == 0)
            row.Children.Add(new CareerAction("加入下一轮准备清单 →", () => _ = LoadTargetsAsync()) { Enabled = !(_busy || Session.Bool("review_stale") || Archived) });
        else
        {
            var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
            foreach (var target in _targets)
            {
                var item = new MenuFlyoutItem { Text = target.Text("stage_label") + " · " + CareerFormat.MonthDay(target.Text("start_at")) };
                var id = target.Text("id");
                item.Click += (_, _) => _ = AddToPrepAsync(question, id);
                menu.Items.Add(item);
            }
            var label = HStack(4, Sans("选择下一轮面试", 12, CareerPalette.Text, Medium), Icon("chevron.down", 9, CareerPalette.Sub));
            var picker = new Border { Child = label, Padding = new Thickness(10, 0, 10, 0), Height = 30, CornerRadius = new CornerRadius(8), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1), Background = Brush(V3.White) };
            row.Children.Add(picker.OnTap(() => menu.ShowAt(picker), "选择下一轮面试"));
            row.Children.Add(new CareerAction("取消", () => { _targets = []; Render(); }, CareerAction.Kind.Text));
        }
        // 模拟下一轮：把题目和建议答法放进首页对话输入框，由用户确认后发送（Web 跳转 /assistant?prompt=）
        row.Children.Add(new CareerAction("模拟下一轮 →", () =>
            WorkspaceShell.Current?.Draft("请围绕以下问题帮我练习面试回答：\n" + question.Text("question") + "\n" + question.Text("suggested_answer"))));
        return new Border { Child = row, Padding = new Thickness(0, 14, 0, 0), Margin = new Thickness(0, 6, 0, 0), BorderBrush = Brush(CareerPalette.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
    }

    UIElement Unmatched(List<JsonNode> notes)
    {
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(SectionTitle("未匹配的笔记", "重新生成报告后，这些笔记对应的题目没有再出现").Also(t => t.Margin = new Thickness(0, 0, 0, -4)));
        foreach (var note in notes)
        {
            var card = VStack(8, Sans(note.Text("question_text"), 13.5, CareerPalette.Text, Medium).Wrap(),
                note.Text("note").Length > 0 ? Sans(note.Text("note"), 12.5, CareerPalette.Sub).Wrap() : null,
                Archived ? null : new CareerAction("删除笔记", () => _ = DeleteNoteAsync(note)));
            stack.Children.Add(new Border { Child = card, Padding = new Thickness(18, 16, 18, 16), CornerRadius = new CornerRadius(12), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1) });
        }
        return stack;
    }

    UIElement? Improvements(JsonNode report, List<JsonNode> questions)
    {
        var items = report.Items("improvements");
        if (items.Count == 0) return null;
        var stack = new StackPanel { Spacing = 10 };
        stack.Children.Add(SectionTitle("改进建议", $"按影响排序 · {items.Count} 条").Also(t => t.Margin = new Thickness(0, 0, 0, -4)));
        foreach (var item in items)
        {
            var key = item.Text("priority") == "key";
            var sources = item.Items("question_indexes").Select(x => (int)(x.Number() ?? 0)).ToList();
            var links = HStack(8);
            if (sources.Count > 0)
            {
                links.Children.Add(Sans("来源", 11, CareerPalette.Faint));
                foreach (var number in sources)
                {
                    var value = number;
                    links.Children.Add(Tappable(CareerChipView.Make($"Q{number}", CareerTone.Blue), () => { _selected = Math.Max(0, questions.FindIndex(x => x.Integer("index") == value)); Render(); }, $"Q{number}"));
                }
            }
            if (item.Text("dimension").Length > 0) { links.Children.Add(Sans("维度", 11, CareerPalette.Faint)); links.Children.Add(CareerChipView.Make(CareerReview.DimensionLabel(item.Text("dimension")), CareerTone.Gray)); }
            var card = VStack(8,
                HStack(10, CareerChipView.Make(key ? "重要" : "建议", key ? CareerTone.Red : CareerTone.Orange), Sans(item.Text("title"), 13.5, CareerPalette.Text, Medium).Wrap()),
                Sans(item.Text("detail"), 12.5, CareerPalette.Sub).Spaced(3).Wrap(),
                links);
            stack.Children.Add(new Border { Child = card, Padding = new Thickness(18, 16, 18, 16), CornerRadius = new CornerRadius(12), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1) });
        }
        return stack;
    }

    // MARK: Report v1

    UIElement ReportV1(JsonNode report)
    {
        var questions = report.Items("questions");
        var overall = CareerReview.Score100(report);
        var improvements = questions.Where(x => x.Text("improvement").Length > 0).ToList();
        var stack = new StackPanel();
        var total = new StackPanel { Spacing = 4, Width = 140 };
        total.Children.Add(HStack(8, Sans("总分", 11.5, CareerPalette.Sub), CareerReview.Grade(overall) is { } grade ? CareerChipView.Make(grade) : null));
        total.Children.Add(Baseline(Serif(overall?.ToString() ?? "—", 48), Sans("/ 100", 13, CareerPalette.Faint)));
        var summary = VStack(10, Sans(report.Text("summary"), 15, CareerPalette.Text, Medium).Wrap(),
            Sans($"识别问题 {questions.Count} 题 · 表现较好 {questions.Count(x => x.Text("strength").Length > 0)} 题 · 待提升 {improvements.Count} 题", 12, CareerPalette.Sub).Wrap());
        summary.VerticalAlignment = VerticalAlignment.Center;
        stack.Children.Add(new Border { Child = Columns(28, (Auto, total), (Star(), summary)), Padding = new Thickness(28, 24, 28, 24), CornerRadius = new CornerRadius(14), Background = Brush(CareerPalette.Soft), Margin = new Thickness(0, 0, 0, 28) });
        stack.Children.Add(SectionTitle("能力维度", "0–10 分 · 依据本轮文字记录"));
        foreach (var (label, key) in new[] { ("项目表达", "project_expression"), ("系统设计", "system_design"), ("沟通表达", "communication") })
        {
            var rating = report.Get(key);
            var score = rating.Number("score");
            var value = Mono(score is { } s ? $"{Format(s)} / 10" : "— / 10", 11.5, CareerPalette.Sub, Medium);
            value.TextAlignment = TextAlignment.Right;
            var block = VStack(6,
                Columns(16, (Px(72), Sans(label, 13, CareerPalette.Text, Medium)), (Star(), Track((score ?? 0) / 10, (score ?? 10) < 6)), (Px(56), value)),
                Sans(rating.Text("reason"), 12, CareerPalette.Sub).Wrap().Pad(88, 0, 0, 0));
            if (rating.Text("evidence").Length > 0) block.Children.Add(Quote(rating.Text("evidence")).Pad(88, 0, 0, 0));
            block.Padding = new Thickness(0, 12, 0, 12);
            stack.Children.Add(block);
        }
        if (questions.Count > 0)
        {
            var index = Math.Min(_selected, questions.Count - 1);
            stack.Children.Add(SectionTitle("逐题表现", "点击题目查看完整回答与分析").Top(16));
            for (var offset = 0; offset < questions.Count; offset++)
            {
                var item = questions[offset];
                UIElement? tag = item.Text("improvement").Length > 0 ? CareerChipView.Make("待提升", CareerTone.Orange) : item.Text("strength").Length > 0 ? CareerChipView.Make("表现较好", CareerTone.Green) : null;
                var row = Columns(14, (Px(24), Mono($"Q{offset + 1}", 11, CareerPalette.Faint, Medium)), (Star(), Sans(item.Text("question"), 13, CareerPalette.Text, Medium).Wrap()), (Auto, tag ?? new Border()));
                foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
                row.Padding = new Thickness(8, 14, 8, 14);
                var target = offset;
                stack.Children.Add(new Border { Child = row, CornerRadius = new CornerRadius(8), Background = Brush(offset == index ? CareerPalette.Soft : Clear) }.OnTap(() => { _selected = target; Render(); }, item.Text("question")));
            }
            var question = questions[index];
            var panel = new StackPanel { Spacing = 10 };
            panel.Children.Add(Sans($"AI 建议的回答 · Q{index + 1}", 11, CareerPalette.Faint));
            panel.Children.Add(Sans(question.Text("question"), 15, CareerPalette.Text, Medium).Wrap());
            if (question.Text("answer").Length > 0) { panel.Children.Add(Heading("我的回答")); panel.Children.Add(Paragraph(question.Text("answer"))); }
            if (question.Text("evidence").Length > 0) panel.Children.Add(Quote(question.Text("evidence")));
            if (question.Text("strength").Length > 0) { panel.Children.Add(Heading("做得好的地方")); panel.Children.Add(Paragraph(question.Text("strength"))); }
            if (question.Text("improvement").Length > 0) { panel.Children.Add(Heading("可以更好")); panel.Children.Add(Paragraph(question.Text("improvement"))); }
            if (question.Text("suggested_answer").Length > 0) { panel.Children.Add(Heading("下次怎么答")); panel.Children.Add(Paragraph(question.Text("suggested_answer"))); }
            panel.Children.Add(PrepActions(question));
            stack.Children.Add(new Border { Child = panel, Padding = new Thickness(20), CornerRadius = new CornerRadius(14), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1), Margin = new Thickness(0, 12, 0, 0) });
        }
        return stack;
    }
}
