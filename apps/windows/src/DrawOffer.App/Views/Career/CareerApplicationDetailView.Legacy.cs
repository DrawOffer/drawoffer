using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;
using Shapes = Microsoft.UI.Xaml.Shapes;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 旧版 04.C01 布局的部件（Mac 同文件里保留但已不在页面上使用的 header / pipeline / nextCard / history / side），
/// 照搬以便其它页面复用与逐项对照。
/// </summary>
public sealed partial class CareerApplicationDetailView
{
    // MARK: Header

    UIElement Header(CareerDetailModel model)
    {
        var snapshot = Raw.Get("job_snapshot");
        var employment = snapshot.Text("employment_type") switch { "full_time" => "正式", "campus" => "校招", "internship" => "实习", _ => null };
        var city = new[] { snapshot.Text("work_city"), snapshot.Text("city"), snapshot.Text("location") }.FirstOrDefault(x => x.Length > 0);
        var salary = new[] { snapshot.Text("salary_text"), snapshot.Text("salary") }.FirstOrDefault(x => x.Length > 0);
        var summary = string.Join(" · ", new[] { city, salary }.OfType<string>());
        var title = Serif(Item.Title, 28).Wrap(2);
        AutomationProperties.SetName(title, Item.Company + "，" + Item.Title);
        var meta = HStack(8, employment is null ? null : CareerChipView.Make(employment, CareerTone.Gray),
            summary.Length == 0 ? null : Sans(summary, 13, CareerPalette.Sub), Sans("·", 13, CareerPalette.Faint), Sans(model.HeaderMeta, 13, CareerPalette.Faint));
        var left = VStack(6, CareerBreadcrumb.Make("← 岗位看板", Item.Company, _back), title, meta);
        var favorite = new CareerAction(Raw.Bool("is_favorite") ? "★ 已收藏" : "☆ 收藏", () => _ = ToggleFavorite(), CareerAction.Kind.Text) { Enabled = !(_busy || _current is null) };
        var more = new Border
        {
            Width = 32, Height = 18, CornerRadius = new CornerRadius(9), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
            Child = Label("•••", 9, CareerPalette.Text, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        more.OnTap(() =>
        {
            var menu = new MenuFlyout();
            void Add(string text, Action run, bool danger = false)
            {
                var item = new MenuFlyoutItem { Text = text };
                if (danger) item.Foreground = Brush(Red);
                item.Click += (_, _) => run();
                menu.Items.Add(item);
            }
            Add("修改求职分类", () => _perform("category", Item));
            Add("岗位详情", OpenJob);
            Add("管理关联资料", () => WorkspaceShell.Current.Select(WorkspaceSection.Datasets));
            if (!Active && Raw.Text("archived_at").Length == 0) Add("归档（从看板隐藏）", () => _perform("archive", Item));
            if (Raw.Text("archived_at").Length > 0) Add("恢复岗位", () => _perform("restore", Item));
            if (Active && Raw.Text("offer_status") == "none" || model.Ended)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
                if (Active && Raw.Text("offer_status") == "none") Add(model.Pending ? "不投了" : "结束本次求职", () => _perform("terminate", Item), true);
                if (model.Ended) Add("删除岗位", () => _perform("delete", Item), true);
            }
            menu.ShowAt(more, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
        }, "更多操作");
        return Spread(left, HStack(8, favorite, new CareerAction("岗位详情", OpenJob), more), 16, VerticalAlignment.Top);
    }

    // MARK: Stepper

    UIElement Pipeline(CareerDetailModel model)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, MinWidth = 780 };
        for (var index = 0; index < model.Steps.Count; index++)
        {
            var step = model.Steps[index];
            var mark = new Grid();
            mark.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
            mark.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            mark.ColumnSpacing = 6;
            mark.Children.Add(StepMark(step.State));
            if (index < model.Steps.Count - 1)
            {
                var line = new Border { Height = 2, Background = Brush(step.State == CareerDetailStepState.Done ? CareerPalette.Green : CareerPalette.Border), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(line, 1);
                mark.Children.Add(line);
            }
            var color = step.State == CareerDetailStepState.Current ? CareerPalette.Blue : step.State == CareerDetailStepState.Failed ? CareerPalette.Red
                : step.State is CareerDetailStepState.Next or CareerDetailStepState.Todo ? CareerPalette.Faint : CareerPalette.Text;
            var label = Sans(step.Label, 13, color, step.State == CareerDetailStepState.Current ? Bold : Medium).Also(t => t.TextTrimming = TextTrimming.None);
            var meta = Label(step.Meta.Length == 0 ? " " : step.Meta, 11, step.State == CareerDetailStepState.Failed ? CareerPalette.Red : CareerPalette.Faint, Medium);
            meta.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            row.Children.Add(VStack(8, mark, label, meta).Also(s => s.MinWidth = 88));
        }
        var scroll = new ScrollViewer { Content = row, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Enabled };
        AutomationProperties.SetName(scroll, "当前阶段：" + model.CurrentLabel);
        return new Border
        {
            Child = VStack(14, Sans("求职进度", 14, CareerPalette.Text, Medium), scroll), Padding = new Thickness(20, 16, 20, 16),
            CornerRadius = new CornerRadius(14), Background = Brush(CareerPalette.Soft), BorderBrush = Brush(CareerPalette.PipelineLine), BorderThickness = new Thickness(1),
        };
    }

    static FrameworkElement StepMark(CareerDetailStepState state)
    {
        switch (state)
        {
            case CareerDetailStepState.Done or CareerDetailStepState.Failed or CareerDetailStepState.Offer:
                return Layer(new Shapes.Ellipse { Width = 18, Height = 18, Fill = Brush(state == CareerDetailStepState.Done ? CareerPalette.Green : state == CareerDetailStepState.Failed ? CareerPalette.Red : CareerPalette.Text) },
                    Label(state == CareerDetailStepState.Done ? "✓" : state == CareerDetailStepState.Failed ? "✕" : "★", 10, V3.White, Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center)).Frame(18, 18);
            case CareerDetailStepState.Current:
                return Layer(new Shapes.Ellipse { Width = 18, Height = 18, Fill = Brush(V3.White), Stroke = Brush(CareerPalette.Blue), StrokeThickness = 1.5 },
                    new Shapes.Ellipse { Width = 9, Height = 9, Fill = Brush(CareerPalette.Blue) }).Frame(18, 18);
            case CareerDetailStepState.Next:
                return new Shapes.Ellipse { Width = 18, Height = 18, Fill = Brush(V3.White), Stroke = Brush(CareerPalette.Dashed), StrokeThickness = 1, StrokeDashArray = [2, 2] };
            default:
                return new Shapes.Ellipse { Width = 18, Height = 18, Fill = Brush(V3.White), Stroke = Brush(CareerPalette.Dashed), StrokeThickness = 1 };
        }
    }

    // MARK: Next action

    UIElement NextCard(CareerDetailNext next)
    {
        var lead = HStack(6, Sans(next.Lead, 11, CareerPalette.Faint, Medium));
        foreach (var chip in next.Chips) lead.Children.Add(CareerChipView.Make(chip));
        var middle = VStack(6, lead, Sans(next.Title, 19, CareerPalette.Text, Medium).Wrap(),
            next.Detail.Length == 0 ? null : Sans(next.Detail, 13, CareerPalette.Sub).Wrap(),
            next.Hint is { } hint ? Sans(hint, 12, CareerPalette.Hint) : null);
        var buttons = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        if (next.Primary is { } primary)
            buttons.Children.Add(new CareerAction(primary.Label, () => Handle(primary.Action), primary.Dark ? CareerAction.Kind.Primary : CareerAction.Kind.Outline, large: true) { Enabled = !(_busy || _loading), HorizontalAlignment = HorizontalAlignment.Right });
        if (next.Secondary.Count > 0)
            buttons.Children.Add(HStack(4, next.Secondary.Select(b => (UIElement)new CareerAction(b.Label, () => Handle(b.Action), b.Danger ? CareerAction.Kind.Danger : CareerAction.Kind.Text) { Enabled = !(_busy || _loading) }).ToArray()).Also(s => s.HorizontalAlignment = HorizontalAlignment.Right));
        var row = Columns(20, (Auto, Tile(next.Tile)), (Star(), middle), (Auto, buttons));
        var accent = new Border { Width = 3, HorizontalAlignment = HorizontalAlignment.Left, Background = Brush(next.Accent == CareerTone.Gray ? CareerPalette.Dashed : CareerPalette.Solid(next.Accent)) };
        // 阴影 #1C1C1A 5%、半径 12、下移 6
        return new Border
        {
            Child = Layer(new Border { Child = row, Padding = new Thickness(20) }, accent), CornerRadius = new CornerRadius(16), Background = Brush(V3.White),
            BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
        }.Elevate(6);
    }

    static UIElement Tile(CareerDetailTile tile)
    {
        switch (tile)
        {
            case CareerDetailTile.Date date:
            {
                var foot = Label(date.Foot, 11, CareerPalette.Sub, Medium).Align(HorizontalAlignment.Center).Pad(0, 0, 0, 6);
                foot.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
                return new Border
                {
                    Width = 88, CornerRadius = new CornerRadius(12), Background = Brush(V3.White), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
                    Child = VStack(0, new Border { Background = Brush(CareerPalette.Text), Padding = new Thickness(0, 4, 0, 4), Child = Sans(date.Head, 11, V3.White, Medium).Align(HorizontalAlignment.Center) },
                        Label(date.Day, 30, CareerPalette.Text, Medium).Align(HorizontalAlignment.Center).Top(6), foot),
                };
            }
            case CareerDetailTile.Status status:
            {
                var color = status.Tone == CareerTone.Gray ? CareerPalette.Text : CareerPalette.Solid(status.Tone);
                var stack = VStack(2, Sans(status.Title, 15, color, Medium).Align(HorizontalAlignment.Center),
                    status.Sub.Length == 0 ? null : Sans(status.Sub, 11, status.Tone == CareerTone.Gray ? CareerPalette.Sub : CareerPalette.Solid(status.Tone)).Align(HorizontalAlignment.Center));
                stack.VerticalAlignment = VerticalAlignment.Center;
                return new Border { Width = 88, Height = 88, CornerRadius = new CornerRadius(12), Background = Brush(CareerPalette.Background(status.Tone)), Child = stack };
            }
            default:
                return new Border();
        }
    }
}
