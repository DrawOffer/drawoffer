using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// 换行排布（Mac `FlowRow` / `FlowLayout`）：横向间距与行距相同；trailing 时每行靠右（`justify-content: flex-end`）。
/// </summary>
public sealed class VariableSizedFlow(double spacing, bool trailing = false)
{
    public Panel Panel { get; } = new FlowPanel(spacing, trailing);
    public void Add(UIElement element) => Panel.Children.Add(element);

    sealed class FlowPanel(double spacing, bool trailing) : Panel
    {
        protected override Size MeasureOverride(Size available)
        {
            var width = double.IsInfinity(available.Width) ? 400 : available.Width;
            double x = 0, y = 0, line = 0, widest = 0;
            foreach (var child in Children)
            {
                child.Measure(new Size(width, double.PositiveInfinity));
                var size = child.DesiredSize;
                if (x + size.Width > width && x > 0) { x = 0; y += line + spacing; line = 0; }
                x += size.Width + spacing;
                widest = Math.Max(widest, x - spacing);
                line = Math.Max(line, size.Height);
            }
            return new Size(trailing || !double.IsInfinity(available.Width) ? width : widest, y + line);
        }

        protected override Size ArrangeOverride(Size final)
        {
            var rows = new List<List<UIElement>> { new() };
            double x = 0;
            foreach (var child in Children)
            {
                var size = child.DesiredSize;
                if (x + size.Width > final.Width && x > 0) { rows.Add([]); x = 0; }
                rows[^1].Add(child);
                x += size.Width + spacing;
            }
            double y = 0;
            foreach (var row in rows)
            {
                var total = row.Sum(c => c.DesiredSize.Width) + spacing * Math.Max(0, row.Count - 1);
                var cursor = trailing ? Math.Max(0, final.Width - total) : 0;
                var line = row.Count == 0 ? 0 : row.Max(c => c.DesiredSize.Height);
                foreach (var child in row)
                {
                    child.Arrange(new Rect(cursor, y, child.DesiredSize.Width, child.DesiredSize.Height));
                    cursor += child.DesiredSize.Width + spacing;
                }
                y += line + spacing;
            }
            return final;
        }
    }
}
