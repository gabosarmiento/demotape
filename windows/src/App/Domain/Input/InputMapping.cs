namespace DemoTape.Domain.Input;

/// <summary>
/// Pure input-normalization helpers shared by the Windows event recorder. Kept in Domain so the
/// coordinate/modifier mapping (the part that's easy to get subtly wrong) is unit-testable
/// without any Win32 dependency. Mirrors the macOS <c>EventRecorder.normalize</c> and modifier
/// handling, but with Windows conventions.
/// </summary>
public static class InputMapping
{
    /// <summary>
    /// Normalizes a screen-pixel point to 0..1 (top-left origin) within a capture region,
    /// clamped to the region. <paramref name="regionW"/>/<paramref name="regionH"/> are in pixels.
    /// </summary>
    public static (double X, double Y) Normalize(
        double px, double py, double regionX, double regionY, double regionW, double regionH)
    {
        if (regionW <= 0 || regionH <= 0) return (0, 0);
        double x = (px - regionX) / regionW;
        double y = (py - regionY) / regionH;
        return (Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
    }

    /// <summary>Windows mouse-message button → the sidecar button string ("left"/"right"/"other").</summary>
    public static string ButtonName(bool isLeft, bool isRight) =>
        isLeft ? "left" : isRight ? "right" : "other";

    [Flags]
    public enum Mod { None = 0, Ctrl = 1, Shift = 2, Alt = 4, Win = 8 }

    /// <summary>Maps pressed-modifier flags to the normalized modifier names used by FocusTimeline.</summary>
    public static List<string> Modifiers(Mod mods)
    {
        var list = new List<string>();
        if (mods.HasFlag(Mod.Ctrl)) list.Add("ctrl");
        if (mods.HasFlag(Mod.Shift)) list.Add("shift");
        if (mods.HasFlag(Mod.Alt)) list.Add("alt");
        if (mods.HasFlag(Mod.Win)) list.Add("win");
        return list;
    }

    /// <summary>True if the chord counts as a shortcut worth badging (has Ctrl/Alt/Win).</summary>
    public static bool IsShortcut(Mod mods) =>
        mods.HasFlag(Mod.Ctrl) || mods.HasFlag(Mod.Alt) || mods.HasFlag(Mod.Win);
}
