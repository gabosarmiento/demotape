namespace DemoTape.Domain.Settings;

/// <summary>
/// Pure scheduling rule for the first-run welcome screen, ported from the macOS
/// <c>Settings.shouldShowWelcome</c>: show it for the first few launches, then only about monthly, so
/// it introduces the app without nagging returning users. Kept dependency-free and unit-tested.
/// </summary>
public static class WelcomeSchedule
{
    /// <summary>Always show the welcome for at least this many launches.</summary>
    public const int MinLaunchesToShow = 3;

    /// <summary>After the initial launches, show again only if this long has passed.</summary>
    public const double MonthSeconds = 30 * 24 * 60 * 60;

    /// <summary>Whether to show the welcome screen given how often/recently it has been shown.</summary>
    public static bool ShouldShow(int showCount, double lastShownUnix, double nowUnix)
    {
        if (showCount < MinLaunchesToShow) return true;
        return (nowUnix - lastShownUnix) > MonthSeconds;
    }
}
