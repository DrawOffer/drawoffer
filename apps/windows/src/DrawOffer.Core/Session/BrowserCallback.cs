namespace DrawOffer.Core.Session;

/// <summary>`drawoffer://auth/callback?code=…&amp;state=…` 的解析，对应 Mac `completeBrowserLogin` 里的校验：scheme、host、path 必须完全一致。</summary>
public static class BrowserCallback
{
    public const string Scheme = "drawoffer";

    /// <summary>不是登录回调时返回 null；同名参数取第一个。</summary>
    public static Dictionary<string, string>? Parse(Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Scheme || uri.Host != "auth" || uri.AbsolutePath != "/callback") return null;
        var result = new Dictionary<string, string>();
        foreach (var part in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var pair = part.Split('=', 2);
            var key = Uri.UnescapeDataString(pair[0].Replace('+', ' '));
            if (!result.ContainsKey(key)) result[key] = pair.Length == 2 ? Uri.UnescapeDataString(pair[1].Replace('+', ' ')) : "";
        }
        return result;
    }

    /// <summary>从命令行参数里找回调地址（协议激活时 Windows 把地址作为第一个参数传给新进程）。</summary>
    public static Uri? FromArguments(IEnumerable<string> arguments) =>
        arguments.Select(x => Uri.TryCreate(x, UriKind.Absolute, out var uri) ? uri : null).FirstOrDefault(x => x is not null && Parse(x) is not null);
}
