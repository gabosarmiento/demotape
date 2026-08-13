using DemoTape.Domain.Ai;
using Xunit;

namespace DemoTape.Tests;

public class CaptionEditTests
{
    private static readonly CaptionCue[] OriginalCues =
    {
        new(0.0, 1.0, "Hello world"),
        new(1.0, 2.5, "this is a test"),
        new(2.5, 4.0, "end of clip"),
    };

    [Fact]
    public void ApplyEdits_SameCount_UpdatesTextKeepsTimings()
    {
        // Edit each line to a new wording (same cue count) — the bug was that stale text was kept.
        const string edited = "Hi there\nupdated middle\nfinished";
        var result = CaptionEditor.ApplyEdits(OriginalCues, edited);

        Assert.Equal(3, result.Count);

        // Text is updated from the edited input.
        Assert.Equal("Hi there",      result[0].Text);
        Assert.Equal("updated middle", result[1].Text);
        Assert.Equal("finished",       result[2].Text);

        // Timings are preserved (not stale-replaced).
        Assert.Equal(0.0, result[0].Start);
        Assert.Equal(1.0, result[0].End);
        Assert.Equal(1.0, result[1].Start);
        Assert.Equal(2.5, result[1].End);
        Assert.Equal(2.5, result[2].Start);
        Assert.Equal(4.0, result[2].End);
    }

    [Fact]
    public void ApplyEdits_ShorterEdit_DropsExcessCues()
    {
        // Edit shortens the list to 1 line — the remaining 2 original cues must be dropped.
        const string edited = "just one line now";
        var result = CaptionEditor.ApplyEdits(OriginalCues, edited);

        Assert.Single(result);
        Assert.Equal("just one line now", result[0].Text);
        // Timing from the first original cue is preserved.
        Assert.Equal(0.0, result[0].Start);
        Assert.Equal(1.0, result[0].End);
    }

    [Fact]
    public void ApplyEdits_LongerEdit_AppendsTimelessCues()
    {
        // Edit adds a 4th line that had no original cue → timeless (0, 0).
        const string edited = "Hello world\nthis is a test\nend of clip\nextra new line";
        var result = CaptionEditor.ApplyEdits(OriginalCues, edited);

        Assert.Equal(4, result.Count);
        Assert.Equal("extra new line", result[3].Text);
        Assert.Equal(0.0, result[3].Start);
        Assert.Equal(0.0, result[3].End);
    }

    [Fact]
    public void ApplyEdits_BlankLinesIgnored()
    {
        const string edited = "Hello world\n\n   \nthis is a test\n\nend of clip";
        var result = CaptionEditor.ApplyEdits(OriginalCues, edited);

        // Blank / whitespace-only lines are filtered, so the effective line count is 3.
        Assert.Equal(3, result.Count);
        Assert.Equal("Hello world",    result[0].Text);
        Assert.Equal("this is a test", result[1].Text);
        Assert.Equal("end of clip",    result[2].Text);
    }

    [Fact]
    public void ApplyEdits_EmptyEdit_ReturnsEmptyList()
    {
        var result = CaptionEditor.ApplyEdits(OriginalCues, "   \n\n  ");
        Assert.Empty(result);
    }
}
