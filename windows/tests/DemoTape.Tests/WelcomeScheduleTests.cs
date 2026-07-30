using DemoTape.Domain.Settings;
using Xunit;

namespace DemoTape.Tests;

public class WelcomeScheduleTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void ShowsForTheFirstFewLaunches(int count)
        => Assert.True(WelcomeSchedule.ShouldShow(count, lastShownUnix: 1000, nowUnix: 1000));

    [Fact]
    public void HidesOnceSeenEnough_AndRecent()
    {
        double now = 1_000_000;
        Assert.False(WelcomeSchedule.ShouldShow(WelcomeSchedule.MinLaunchesToShow, now - 60, now));
    }

    [Fact]
    public void ShowsAgainAfterAboutAMonth()
    {
        double now = 100_000_000;
        double lastShown = now - WelcomeSchedule.MonthSeconds - 1;
        Assert.True(WelcomeSchedule.ShouldShow(WelcomeSchedule.MinLaunchesToShow, lastShown, now));
    }
}
