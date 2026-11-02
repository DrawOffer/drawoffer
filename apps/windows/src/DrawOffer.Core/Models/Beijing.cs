namespace DrawOffer.Core.Models;

/// <summary>
/// Beijing time, the one time zone the product shows and counts days in. Times travel as UTC
/// ISO 8601; only their wall-clock reading is fixed to Asia/Shanghai, whatever zone Windows is
/// set to. Use these instead of <c>ToLocalTime()</c>, <c>DateTime.Now</c>/<c>Today</c> and
/// <c>TimeZoneInfo.Local</c>.
/// </summary>
public static class Beijing {
    public const string Identifier="Asia/Shanghai";
    public static readonly TimeSpan Offset=TimeSpan.FromHours(8);
    // China has kept UTC+8 without daylight saving since 1991, so a fixed offset is exact and
    // needs no time-zone database (Windows ids differ from IANA ones).
    public static readonly TimeZoneInfo Zone=TimeZoneInfo.CreateCustomTimeZone(Identifier,Offset,"China Standard Time","China Standard Time");
    public static DateTimeOffset Now=>DateTimeOffset.UtcNow.ToOffset(Offset);
    public static DateTime Today=>Now.Date;
    public static DateOnly TodayDate=>DateOnly.FromDateTime(Now.DateTime);
    /// <summary>The same instant with the Beijing offset, so its Date, Hour and ToString read Beijing time.</summary>
    public static DateTimeOffset ToBeijing(this DateTimeOffset value)=>value.ToOffset(Offset);
    /// <summary>A Beijing wall-clock date and time as an instant.</summary>
    public static DateTimeOffset At(DateOnly date,TimeSpan time=default)=>new(date.ToDateTime(TimeOnly.MinValue).Add(time),Offset);
}
