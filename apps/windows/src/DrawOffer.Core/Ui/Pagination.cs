namespace DrawOffer.Core.Ui;

/// <summary>Web `components/ui/pagination.tsx` 的页码规则，对应 Mac `V3Pagination.numbers`。</summary>
public static class Pagination
{
    /// <summary>不超过 7 页时全部列出；否则保留首页、末页与当前页前后各一页，相邻不连续处插入 null 表示省略号。</summary>
    public static List<int?> Numbers(int current, int total)
    {
        if (total <= 7) return Enumerable.Range(1, Math.Max(1, total)).Select(x => (int?)x).ToList();
        var pages = new SortedSet<int> { 1, current - 1, current, current + 1, total }.Where(x => x > 0 && x <= total).ToList();
        var output = new List<int?>();
        for (var i = 0; i < pages.Count; i++)
        {
            if (i > 0 && pages[i] - pages[i - 1] > 1) output.Add(null);
            output.Add(pages[i]);
        }
        return output;
    }
}
