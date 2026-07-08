using DemoTape.Domain.Publishing;
using Xunit;

namespace DemoTape.Tests;

public class WebPublishPlannerTests
{
    [Fact]
    public void EstimatedBytes_ScalesWithDurationAndBitrate()
    {
        // 540p = 1820 kbps + 96 kbps audio, over 10s → (1916 kbps * 10s) / 8 * 1000 bytes.
        long bytes = WebPublishPlanner.EstimatedBytes(10, 540);
        Assert.Equal((long)(10 * (1820 + 96) * 1000 / 8), bytes);
    }

    [Fact]
    public void EstimatedBytes_SumsMultipleTiers()
    {
        long total = WebPublishPlanner.EstimatedBytes(30, new[] { 360, 720 });
        long expected = WebPublishPlanner.EstimatedBytes(30, 360) + WebPublishPlanner.EstimatedBytes(30, 720);
        Assert.Equal(expected, total);
    }

    [Fact]
    public void EstimateSummary_ListsTiersSortedWithSize()
    {
        var s = WebPublishPlanner.EstimateSummary(30, new[] { 720, 360 });
        Assert.Contains("360p, 720p", s);
        Assert.Contains("30s", s);
        Assert.Contains("MB total", s);
    }

    [Fact]
    public void EstimateSummary_HandlesEmptySelection()
    {
        Assert.Equal("Select at least one quality.", WebPublishPlanner.EstimateSummary(10, Array.Empty<int>()));
    }

    [Fact]
    public void WebFolderName_StripsStyledSuffix()
    {
        Assert.Equal("DemoTape 2026-07-08-web", WebPublishPlanner.WebFolderName("DemoTape 2026-07-08.styled"));
    }

    [Fact]
    public void BuildEmbedHtml_OrdersLargestFirst_WithBreakpoints_AndFallback()
    {
        var html = WebPublishPlanner.BuildEmbedHtml(new[] { 360, 540, 720 });
        var lines = html.Split('\n');

        // Largest first with a media query.
        Assert.Contains("demo-720p.mp4", lines[1]);
        Assert.Contains("min-width: 1000px", lines[1]);
        Assert.Contains("demo-540p.mp4", lines[2]);
        Assert.Contains("min-width: 760px", lines[2]);
        // Smallest is the fallback (no media query).
        Assert.Contains("demo-360p.mp4", lines[3]);
        Assert.DoesNotContain("min-width", lines[3]);

        Assert.Contains("poster=\"poster.jpg\"", html);
        Assert.Contains("muted loop", html);
    }

    [Fact]
    public void BuildEmbedHtml_SingleTier_HasNoMediaQuery()
    {
        var html = WebPublishPlanner.BuildEmbedHtml(new[] { 540 });
        Assert.Contains("demo-540p.mp4", html);
        Assert.DoesNotContain("min-width", html);
    }

    [Fact]
    public void BuildReadme_ListsFiles()
    {
        var readme = WebPublishPlanner.BuildReadme(new[] { 540, 720 });
        Assert.Contains("demo-720p.mp4", readme);
        Assert.Contains("demo-540p.mp4", readme);
        Assert.Contains("embed.html", readme);
    }
}
