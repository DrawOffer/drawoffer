using DrawOffer.Core.Models;
using Xunit;
namespace DrawOffer.Core.Tests;
public class BeijingTests {
    [Fact] public void ReadsWallClockInShanghaiWhateverTheMachineZone() {
        // 2026-06-10 16:30 UTC is 00:30 on 11 June in Beijing.
        var instant=new DateTimeOffset(2026,6,10,16,30,0,TimeSpan.Zero).ToBeijing();
        Assert.Equal(new DateTime(2026,6,11,0,30,0),instant.DateTime);
        Assert.Equal("2026-06-11 00:30",instant.ToString("yyyy-MM-dd HH:mm"));
        Assert.Equal(TimeSpan.FromHours(8),Beijing.Now.Offset);
    }
    [Fact] public void ScheduleDatesAreBeijingWallClock() {
        var start=ScheduleCalendar.LocalDate(new DateOnly(2026,6,11),TimeSpan.FromHours(9));
        Assert.Equal(new DateTimeOffset(2026,6,11,1,0,0,TimeSpan.Zero),start.ToUniversalTime());
        Assert.Equal(start,Beijing.At(new DateOnly(2026,6,11),TimeSpan.FromHours(9)));
    }
}
