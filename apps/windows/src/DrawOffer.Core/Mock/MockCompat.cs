namespace DrawOffer.Core.Models;

/// <summary>模拟面试沿用 Career 的 Swift 字符语义；UTF-16 截断按 Foundation 修复孤立代理项。</summary>
internal static class MockText
{
    public static string Prefix(string text, int count) => SwiftText.Prefix(text, count);
    public static bool Less(string a, string b) => SwiftText.Compare(a, b) < 0;
}
