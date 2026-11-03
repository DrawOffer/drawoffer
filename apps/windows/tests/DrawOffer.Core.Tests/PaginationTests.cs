using DrawOffer.Core.Ui;
using Xunit;

namespace DrawOffer.Core.Tests;

public sealed class PaginationTests
{
    [Fact]
    public void NumbersMatchMacAndWeb()
    {
        Assert.Equal([1, 2, 3], Pagination.Numbers(2, 3));
        Assert.Equal([1], Pagination.Numbers(1, 0));
        Assert.Equal([1, null, 4, 5, 6, null, 10], Pagination.Numbers(5, 10));
        Assert.Equal([1, 2, null, 10], Pagination.Numbers(1, 10));
        Assert.Equal([1, null, 9, 10], Pagination.Numbers(10, 10));
    }
}
