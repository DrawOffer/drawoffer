using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// SwiftUI `Canvas` / `GraphicsContext` 的对应物：在一个 <see cref="Canvas"/> 上按绝对坐标加 Path 形状。
/// 方法名与 Swift 的 `fill` / `stroke` / `draw(Text)` 对应，图层透明度对应 `layer.opacity`，让 Mac 的绘图代码可以逐行搬过来。
/// </summary>
public sealed class Draw
{
    public Canvas Surface { get; }
    /// <summary>当前图层透明度（Swift `var layer = context; layer.opacity = …`）。</summary>
    public double Opacity { get; set; } = 1;

    public Draw(double width, double height)
    {
        Surface = new Canvas { Width = width, Height = height, IsHitTestVisible = false };
    }

    // MARK: 几何

    /// <summary>多段折线（`Path { move; addLine… }`）；closed 时闭合（`closeSubpath`）。</summary>
    public static Geometry Lines(IEnumerable<Point> points, bool closed = false)
    {
        var list = points.ToList();
        var figure = new PathFigure { StartPoint = list.Count > 0 ? list[0] : default, IsClosed = closed, IsFilled = closed };
        foreach (var point in list.Skip(1)) figure.Segments.Add(new LineSegment { Point = point });
        return new PathGeometry { Figures = { figure } };
    }

    /// <summary>若干独立线段（`move/addLine` 交替，例如刻度与射线）。</summary>
    public static Geometry Segments(IEnumerable<(Point from, Point to)> segments)
    {
        var geometry = new PathGeometry();
        foreach (var (from, to) in segments)
            geometry.Figures.Add(new PathFigure { StartPoint = from, IsClosed = false, IsFilled = false, Segments = { new LineSegment { Point = to } } });
        return geometry;
    }

    // MARK: 绘制

    public void Fill(Geometry geometry, Brush brush) => Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Fill = brush });
    public void Fill(Geometry geometry, Color color) => Fill(geometry, Brush(color));

    public void Stroke(Geometry geometry, Brush brush, double width = 1, bool round = false, double[]? dash = null)
    {
        var path = new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = brush, StrokeThickness = width };
        if (round) { path.StrokeStartLineCap = PenLineCap.Round; path.StrokeEndLineCap = PenLineCap.Round; path.StrokeDashCap = PenLineCap.Round; }
        if (dash is { Length: > 0 })
        {
            // WinUI 的虚线长度以线宽为单位，CSS / SwiftUI 以点为单位：换算一次保持视觉长度
            var collection = new DoubleCollection();
            foreach (var value in dash) collection.Add(value / Math.Max(width, 0.01));
            path.StrokeDashArray = collection;
        }
        Add(path);
    }

    public void Stroke(Geometry geometry, Color color, double width = 1, bool round = false, double[]? dash = null) => Stroke(geometry, Brush(color), width, round, dash);

    /// <summary>
    /// 在画布上放文字（Swift `context.draw(Text, at:)` 默认以中心对齐；`.position(x:y:)` 同样以中心对齐）。
    /// anchor 取 (0..1, 0..1)：(0.5, 0.5) 中心，(0, 0) 左上，(1, 0) 右上，(0.5, 1) 底部居中。
    /// </summary>
    public FrameworkElement Text(FrameworkElement element, Point at, double anchorX = 0.5, double anchorY = 0.5)
    {
        element.Opacity *= Opacity;
        Surface.Children.Add(element);
        Place(element, at, anchorX, anchorY);
        return element;
    }

    /// <summary>按锚点把元素放到坐标上；尺寸确定后再修正一次。</summary>
    public static void Place(FrameworkElement element, Point at, double anchorX, double anchorY)
    {
        void Update()
        {
            element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var size = element.DesiredSize;
            Canvas.SetLeft(element, at.X - size.Width * anchorX);
            Canvas.SetTop(element, at.Y - size.Height * anchorY);
        }
        Update();
        element.SizeChanged += (_, _) => Update();
    }

    void Add(Microsoft.UI.Xaml.Shapes.Path path)
    {
        path.Opacity = Opacity;
        Surface.Children.Add(path);
    }

    /// <summary>`Color.opacity(x)`。</summary>
    public static Color A(Color color, double opacity) => Alpha(color, opacity);
}
