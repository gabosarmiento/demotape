using DemoTape.Domain.Control;
using Xunit;

namespace DemoTape.Tests;

/// <summary>
/// Ported from the macOS <c>DemoControlTests.swift</c>: exhaustive parsing of the <c>demotape://</c>
/// control surface. Pure logic, no GUI/network, so it runs with only the .NET SDK.
/// </summary>
public class DemoControlTests
{
    private static DemoControl.Command? Parse(string s) =>
        Uri.TryCreate(s, UriKind.Absolute, out var url) ? DemoControl.Parse(url) : null;

    [Fact]
    public void StopVariants()
    {
        Assert.Equal(DemoControl.CommandKind.Stop, Parse("demotape://record/stop")!.Kind);
        Assert.Equal(DemoControl.CommandKind.Stop, Parse("demotape://stop")!.Kind);
        Assert.Equal(DemoControl.CommandKind.Stop, Parse("DEMOTAPE://record/STOP")!.Kind);
    }

    [Fact]
    public void StartFullScreenDefaults()
    {
        var c = Parse("demotape://record/start");
        Assert.Equal(DemoControl.CommandKind.Start, c!.Kind);
        Assert.Equal(DemoControl.RegionKind.FullScreen, c.Start!.Region.Kind);
        Assert.Equal(3, c.Start.Countdown);
        Assert.Null(c.Start.Microphone);
        Assert.Null(c.Start.Webcam);
    }

    [Fact]
    public void StartImmediate()
    {
        var c = Parse("demotape://record/start?countdown=0");
        Assert.Equal(0, c!.Start!.Countdown);
    }

    [Fact]
    public void StartNormalizedRegion()
    {
        var c = Parse("demotape://record/start?nx=0.1&ny=0.2&nw=0.5&nh=0.4");
        Assert.Equal(DemoControl.Region.Normalized(0.1, 0.2, 0.5, 0.4), c!.Start!.Region);
    }

    [Fact]
    public void StartPixelRegion()
    {
        var c = Parse("demotape://record/start?mode=area&x=100&y=80&w=1280&h=720");
        Assert.Equal(DemoControl.Region.Pixels(100, 80, 1280, 720), c!.Start!.Region);
    }

    [Fact]
    public void StartInputFlags()
    {
        var c = Parse("demotape://record/start?mic=1&webcam=0");
        Assert.True(c!.Start!.Microphone);
        Assert.False(c.Start.Webcam);
    }

    [Fact]
    public void NormalizedTakesPrecedenceOverPixels()
    {
        var c = Parse("demotape://record/start?nx=0&ny=0&nw=1&nh=1&x=5&y=5&w=5&h=5");
        Assert.Equal(DemoControl.Region.Normalized(0, 0, 1, 1), c!.Start!.Region);
    }

    [Fact]
    public void WebcamOnlyRoute()
    {
        var c = Parse("demotape://record/webcam?countdown=3");
        Assert.True(c!.Start!.WebcamOnly);
        Assert.Equal(3, c.Start.Countdown);
    }

    [Fact]
    public void ScreenStartIsNotWebcamOnly()
    {
        // A webcam=1 QUERY on a screen recording turns on the PiP bubble, not webcam-only mode.
        var c = Parse("demotape://record/start?webcam=1");
        Assert.False(c!.Start!.WebcamOnly);
        Assert.True(c.Start.Webcam);
    }

    [Fact]
    public void RejectsForeignSchemeAndGarbage()
    {
        Assert.Null(Parse("https://record/start"));
        Assert.Null(Parse("demotape://record/pause"));
        Assert.Null(Parse("demotape://"));
    }

    [Fact]
    public void CursorMove()
    {
        var c = Parse("demotape://cursor/move?x=640&y=360");
        Assert.Equal(DemoControl.CommandKind.Cursor, c!.Kind);
        Assert.Equal(640, c.CursorX);
        Assert.Equal(360, c.CursorY);
        Assert.False(c.Click);
    }

    [Fact]
    public void CursorClick()
    {
        var c = Parse("demotape://cursor/click?x=12&y=34");
        Assert.Equal(12, c!.CursorX);
        Assert.Equal(34, c.CursorY);
        Assert.True(c.Click);
    }

    [Fact]
    public void CursorRequiresCoordinates()
    {
        Assert.Null(Parse("demotape://cursor/click"));
        Assert.Null(Parse("demotape://cursor/move?x=10"));
    }

    // --- ui/open ---

    [Fact]
    public void ParseOpenUiByQuery()
    {
        var c = Parse("demotape://ui/open?window=publish");
        Assert.Equal(DemoControl.CommandKind.OpenUi, c!.Kind);
        Assert.Equal(DemoControl.UiWindow.Publish, c.Window);
    }

    [Fact]
    public void ParseOpenUiShorthandPath()
    {
        var c = Parse("demotape://ui/about");
        Assert.Equal(DemoControl.UiWindow.About, c!.Window);
    }

    [Fact]
    public void ParseOpenUiIsCaseInsensitive()
    {
        var c = Parse("demotape://ui/open?window=COMPOSER");
        Assert.Equal(DemoControl.UiWindow.Composer, c!.Window);
    }

    [Fact]
    public void ParseOpenUiRejectsUnknownWindow()
    {
        Assert.Null(Parse("demotape://ui/open?window=nope"));
    }

    [Fact]
    public void EveryWindowCaseParses()
    {
        foreach (DemoControl.UiWindow w in Enum.GetValues<DemoControl.UiWindow>())
        {
            var c = Parse($"demotape://ui/open?window={w.ToString().ToLowerInvariant()}");
            Assert.Equal(w, c!.Window);
        }
    }

    // --- cursor glide ---

    [Fact]
    public void PlainCursorDoesNotGlide()
    {
        var c = Parse("demotape://cursor?x=100&y=200");
        Assert.Equal(0, c!.GlideMs);
    }

    [Fact]
    public void GlidePathGetsDefaultDuration()
    {
        var c = Parse("demotape://cursor/glide?x=100&y=200");
        Assert.Equal(420, c!.GlideMs);
    }

    [Fact]
    public void ExplicitMsOverridesGlideDefault()
    {
        var c = Parse("demotape://cursor/glide?x=10&y=20&ms=900");
        Assert.Equal(900, c!.GlideMs);
    }

    [Fact]
    public void MsWorksWithoutGlidePathSegment()
    {
        var c = Parse("demotape://cursor?x=10&y=20&ms=250");
        Assert.Equal(250, c!.GlideMs);
    }

    [Fact]
    public void GlideAndClickCombine()
    {
        var c = Parse("demotape://cursor/glide/click?x=5&y=6&ms=300");
        Assert.True(c!.Click);
        Assert.Equal(300, c.GlideMs);
    }

    [Fact]
    public void NegativeDurationIsClampedToZero()
    {
        var c = Parse("demotape://cursor?x=1&y=2&ms=-500");
        Assert.Equal(0, c!.GlideMs);
    }

    [Fact]
    public void CursorStillRequiresBothCoordinates()
    {
        Assert.Null(Parse("demotape://cursor/glide?x=10"));
    }

    // --- semantic targeting ---

    [Fact]
    public void ParseElementClickByLabel()
    {
        var c = Parse("demotape://ui/click?label=Export");
        Assert.Equal(DemoControl.CommandKind.Element, c!.Kind);
        Assert.Equal("Export", c.Query!.Label);
        Assert.True(c.Click);
    }

    [Fact]
    public void ParseElementFindDoesNotClick()
    {
        var c = Parse("demotape://ui/find?label=Export");
        Assert.Equal("Export", c!.Query!.Label);
        Assert.False(c.Click);
    }

    [Fact]
    public void ParseElementCarriesRoleAppAndIndex()
    {
        var c = Parse("demotape://ui/click?label=Allow&role=AXButton&app=Safari&index=2");
        Assert.Equal(new DemoControl.ElementQuery("Allow", "AXButton", "Safari", 2), c!.Query);
        Assert.True(c.Click);
    }

    [Fact]
    public void ParseElementRequiresALabel()
    {
        Assert.Null(Parse("demotape://ui/click?role=AXButton"));
    }

    [Fact]
    public void ParseDumpUi()
    {
        Assert.Equal(DemoControl.CommandKind.DumpUi, Parse("demotape://ui/dump")!.Kind);
        Assert.Null(Parse("demotape://ui/dump")!.App);
        Assert.Equal("Safari", Parse("demotape://ui/dump?app=Safari")!.App);
    }

    // --- + decoding ---

    [Fact]
    public void PlusIsDecodedAsSpaceInLabels()
    {
        var c = Parse("demotape://ui/click?label=Check+for+Updates");
        Assert.Equal("Check for Updates", c!.Query!.Label);
    }

    [Fact]
    public void PercentEncodedSpacesStillWork()
    {
        var c = Parse("demotape://ui/click?label=Check%20for%20Updates");
        Assert.Equal("Check for Updates", c!.Query!.Label);
    }

    [Fact]
    public void PlusDecodingAppliesToAppNames()
    {
        var c = Parse("demotape://ui/dump?app=Visual+Studio+Code");
        Assert.Equal("Visual Studio Code", c!.App);
    }

    // --- menu hold ---

    [Fact]
    public void MenuHoldIsParsed()
    {
        var c = Parse("demotape://ui/open?window=menu&hold=2500");
        Assert.Equal(DemoControl.UiWindow.Menu, c!.Window);
        Assert.Equal(2500, c.HoldMs);
    }

    [Fact]
    public void HoldDefaultsToZeroMeaningNoAutoDismiss()
    {
        Assert.Equal(0, Parse("demotape://ui/open?window=menu")!.HoldMs);
    }

    [Fact]
    public void NegativeHoldIsClamped()
    {
        Assert.Equal(0, Parse("demotape://ui/open?window=menu&hold=-400")!.HoldMs);
    }

    // --- real OS typing ---

    [Fact]
    public void ParseTypeText()
    {
        var c = Parse("demotape://type?text=hello%20world");
        Assert.Equal(DemoControl.CommandKind.Type, c!.Kind);
        Assert.Equal("hello world", c.Text);
        Assert.Equal(0, c.Cps);
        Assert.Null(c.ExpectedApp);
    }

    [Fact]
    public void ParseTypeWithRate()
    {
        var c = Parse("demotape://type?text=abc&cps=12.5");
        Assert.Equal("abc", c!.Text);
        Assert.Equal(12.5, c.Cps);
    }

    [Fact]
    public void ParseTypeDecodesPlusAsSpace()
    {
        var c = Parse("demotape://type?text=roll+it+back");
        Assert.Equal("roll it back", c!.Text);
    }

    [Fact]
    public void ParseTypeRequiresText()
    {
        Assert.Null(Parse("demotape://type?cps=10"));
        Assert.Null(Parse("demotape://type?text="));
    }

    [Fact]
    public void ParseTypeClampsNegativeRate()
    {
        var c = Parse("demotape://type?text=abc&cps=-5");
        Assert.Equal("abc", c!.Text);
        Assert.Equal(0, c.Cps);
    }

    // --- typing activity ---

    [Fact]
    public void ParseTypingActivity()
    {
        var c = Parse("demotape://typing?chars=42&cps=14");
        Assert.Equal(DemoControl.CommandKind.TypingActivity, c!.Kind);
        Assert.Equal(42, c.Chars);
        Assert.Equal(14, c.Cps);
        Assert.Null(c.Caret);
    }

    [Fact]
    public void TypingActivityRateIsOptional()
    {
        var c = Parse("demotape://typing?chars=8");
        Assert.Equal(8, c!.Chars);
        Assert.Equal(0, c.Cps);
    }

    [Fact]
    public void TypingActivityRequiresPositiveCount()
    {
        Assert.Null(Parse("demotape://typing?chars=0"));
        Assert.Null(Parse("demotape://typing?cps=14"));
    }

    [Fact]
    public void TypeCarriesExpectedApp()
    {
        var c = Parse("demotape://type?text=hi&app=Chromium");
        Assert.Equal("Chromium", c!.ExpectedApp);
    }

    [Fact]
    public void ExpectedAppSurvivesPlusDecoding()
    {
        var c = Parse("demotape://type?text=hi&app=Google+Chrome");
        Assert.Equal("Google Chrome", c!.ExpectedApp);
    }

    [Fact]
    public void TypingActivityCarriesCaret()
    {
        var c = Parse("demotape://typing?chars=20&cps=14&x=420&y=680");
        Assert.Equal(new DemoControl.Point(420, 680), c!.Caret);
    }

    [Fact]
    public void CaretNeedsBothCoordinates()
    {
        var c = Parse("demotape://typing?chars=20&x=420");
        Assert.Null(c!.Caret);
    }

    // --- cursor path ---

    [Fact]
    public void ParsePathWithSeveralPoints()
    {
        var c = Parse("demotape://cursor/path?pts=120,80;200,140;260,90&ms=1400");
        Assert.Equal(DemoControl.CommandKind.CursorPath, c!.Kind);
        Assert.Equal(new[]
        {
            new DemoControl.Point(120, 80), new DemoControl.Point(200, 140), new DemoControl.Point(260, 90)
        }, c.PathPoints);
        Assert.Equal(1400, c.PathMs);
    }

    [Fact]
    public void PathDurationDefaultsWhenAbsent()
    {
        var c = Parse("demotape://cursor/path?pts=10,10;20,20");
        Assert.Equal(900, c!.PathMs);
    }

    [Fact]
    public void PathDurationHasAFloorSoItCannotFlash()
    {
        var c = Parse("demotape://cursor/path?pts=10,10;20,20&ms=5");
        Assert.Equal(120, c!.PathMs);
    }

    [Fact]
    public void PathNeedsAtLeastTwoPoints()
    {
        Assert.Null(Parse("demotape://cursor/path?pts=10,10"));
        Assert.Null(Parse("demotape://cursor/path?pts="));
        Assert.Null(Parse("demotape://cursor/path?ms=900"));
    }

    [Fact]
    public void PathSkipsMalformedPairsRatherThanFailing()
    {
        var c = Parse("demotape://cursor/path?pts=10,10;bad;30,30&ms=500");
        Assert.Equal(new[] { new DemoControl.Point(10, 10), new DemoControl.Point(30, 30) }, c!.PathPoints);
        Assert.Equal(500, c.PathMs);
    }
}
