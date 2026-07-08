using DemoTape.Domain.Models;
using DemoTape.Domain.Rendering;
using Xunit;

namespace DemoTape.Tests;

public class FocusTimelineTests
{
    private static RecordingMetadata Meta(
        IEnumerable<ClickSample>? clicks = null,
        IEnumerable<CursorSample>? cursor = null,
        IEnumerable<KeySample>? keys = null) => new()
    {
        StartedAt = DateTimeOffset.UnixEpoch,
        Duration = 10,
        Clicks = clicks?.ToList() ?? new(),
        Cursor = cursor?.ToList() ?? new(),
        Keys = keys?.ToList() ?? new(),
    };

    [Fact]
    public void Activity_IsZero_WithNoEvents()
    {
        var ft = new FocusTimeline(Meta());
        Assert.Equal(0, ft.Activity(5));
    }

    [Fact]
    public void Activity_PeaksDuringClickHold()
    {
        var ft = new FocusTimeline(Meta(clicks: new[] { new ClickSample { T = 2, X = 0.5, Y = 0.5 } }));
        // 0.5s after the click is within the 1.6s hold window → full activity.
        Assert.Equal(1.0, ft.Activity(2.5), 3);
        // Long after the click (past ramp-out) → back to zero.
        Assert.Equal(0.0, ft.Activity(6.0), 3);
    }

    [Fact]
    public void Target_ScaleRisesWithActivity_AndClampsCenter()
    {
        var ft = new FocusTimeline(
            Meta(clicks: new[] { new ClickSample { T = 1, X = 0.0, Y = 0.0 } }),
            maxZoom: 2.0);

        var idle = ft.Target(8.0);
        Assert.Equal(1.0, idle.Scale, 3);         // no activity → no zoom
        Assert.Equal(0.5, idle.CenterX, 3);       // centered

        var active = ft.Target(1.3);
        Assert.True(active.Scale > 1.5);          // zoomed in near a click
        // Center is clamped so the viewport stays on-screen (>= 0.5/scale).
        double half = 0.5 / active.Scale;
        Assert.True(active.CenterX >= half - 1e-9);
        Assert.True(active.CenterY >= half - 1e-9);
    }

    [Fact]
    public void FocusAnchor_HoldsOnClickedField_WhileTyping()
    {
        // Click a field at (0.8, 0.3), then type shortly after. Camera should hold on the field,
        // not follow the cursor which sits at center.
        var ft = new FocusTimeline(Meta(
            clicks: new[] { new ClickSample { T = 1, X = 0.8, Y = 0.3 } },
            cursor: new[] { new CursorSample { T = 0, X = 0.5, Y = 0.5 }, new CursorSample { T = 3, X = 0.5, Y = 0.5 } },
            keys: new[] { new KeySample { T = 1.5, KeyCode = 65, Chars = "a" } }));

        var target = ft.Target(1.6);
        // With full activity the center should bias toward the clicked field (x > 0.5).
        Assert.True(target.CenterX > 0.5);
    }

    [Fact]
    public void CursorPoint_InterpolatesLinearly()
    {
        var ft = new FocusTimeline(Meta(cursor: new[]
        {
            new CursorSample { T = 0, X = 0.0, Y = 0.0 },
            new CursorSample { T = 2, X = 1.0, Y = 0.5 },
        }));
        var mid = ft.CursorPoint(1.0);
        Assert.Equal(0.5, mid.X, 3);
        Assert.Equal(0.25, mid.Y, 3);
    }

    [Fact]
    public void ShortcutBadge_ShownOnlyForModifierChords()
    {
        var ft = new FocusTimeline(Meta(keys: new[]
        {
            new KeySample { T = 1, KeyCode = 67, Chars = "c", Modifiers = new() { "ctrl" } },
            new KeySample { T = 5, KeyCode = 65, Chars = "a" }, // plain typing → no badge
        }));

        Assert.Equal("Ctrl+C", ft.ShortcutBadge(1.2));
        Assert.Null(ft.ShortcutBadge(5.2));   // plain key
        Assert.Null(ft.ShortcutBadge(3.0));   // outside the window of the Ctrl+C
    }

    [Theory]
    [InlineData(new[] { "ctrl", "shift" }, 67, "c", "Ctrl+Shift+C")]
    [InlineData(new[] { "alt" }, 0x0D, "", "Alt+Enter")]
    [InlineData(new[] { "ctrl" }, 0x25, "", "Ctrl+←")]
    public void BadgeLabel_FormatsWindowsChords(string[] mods, int code, string chars, string expected)
    {
        var k = new KeySample { KeyCode = code, Chars = chars, Modifiers = mods.ToList() };
        Assert.Equal(expected, FocusTimeline.BadgeLabel(k));
    }
}
