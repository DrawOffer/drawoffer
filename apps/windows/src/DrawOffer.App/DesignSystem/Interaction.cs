using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// SwiftUI `Button(...).buttonStyle(.plain)` + `.onHover` 的对应物：给任意元素加点按、悬停与键盘触发，
/// 不引入 WinUI Button 的 Fluent 模板，外观完全由调用方决定。
/// </summary>
public static class Interaction
{
    /// <summary>点按（指针抬起在元素内时触发）；Enter / Space 同样触发。name 设为读屏名称。</summary>
    public static T OnTap<T>(this T element, Action action, string? name = null, Func<bool>? enabled = null) where T : FrameworkElement
    {
        var pressed = false;
        bool On() => enabled?.Invoke() ?? true;
        element.PointerPressed += (_, e) => { if (On()) { pressed = true; e.Handled = true; } };
        element.PointerReleased += (_, e) => { if (pressed && On()) { pressed = false; e.Handled = true; action(); } };
        element.PointerCanceled += (_, _) => pressed = false;
        element.PointerExited += (_, _) => pressed = false;
        element.PointerEntered += (_, _) => Cursor(element, On());
        if (element is Control control)
        {
            control.IsTabStop = true;
            control.KeyDown += (_, e) => { if (On() && e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; action(); } };
        }
        if (name is not null) AutomationProperties.SetName(element, name);
        return element;
    }

    /// <summary>悬停状态（`.onHover`）。</summary>
    public static T OnHover<T>(this T element, Action<bool> changed) where T : FrameworkElement
    {
        element.PointerEntered += (_, _) => changed(true);
        element.PointerExited += (_, _) => changed(false);
        element.PointerCanceled += (_, _) => changed(false);
        return element;
    }

    /// <summary>就地配置一个元素再返回它（Kotlin `also`），用于链式构建里补设少量属性。</summary>
    public static T Also<T>(this T value, Action<T> configure) { configure(value); return value; }

    /// <summary>双击（`.onTapGesture(count: 2)`）。</summary>
    public static T OnDoubleTap<T>(this T element, Action action) where T : UIElement
    {
        element.DoubleTapped += (_, e) => { e.Handled = true; action(); };
        return element;
    }

    static void Cursor(FrameworkElement element, bool hand)
    {
        // ProtectedCursor 只能在派生类里设置；自绘部件都继承 BorderControl，这里用反射兜底给其他元素设置手形光标
        var property = typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        property?.SetValue(element, InputSystemCursor.Create(hand ? InputSystemCursorShape.Hand : InputSystemCursorShape.Arrow));
    }
}
