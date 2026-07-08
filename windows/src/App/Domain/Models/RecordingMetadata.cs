using System.Text.Json.Serialization;

namespace DemoTape.Domain.Models;

/// <summary>
/// Event timeline captured alongside a recording, persisted as a JSON sidecar
/// (<c>*.events.json</c>) next to the raw capture. This mirrors the macOS
/// <c>RecordingMetadata</c> struct 1:1 so the on-disk format is a stable, portable contract.
///
/// All positions are normalized to the recorded display/region: <c>X</c> and <c>Y</c> in
/// 0..1 with a top-left origin, so they map onto any output size. Times (<c>T</c>) are
/// seconds from the start of the recording.
/// </summary>
public sealed class RecordingMetadata
{
    [JsonPropertyName("version")]
    public int Version { get; set; } = 1;

    [JsonPropertyName("startedAt")]
    public DateTimeOffset StartedAt { get; set; }

    [JsonPropertyName("duration")]
    public double Duration { get; set; }

    [JsonPropertyName("capturedKeystrokes")]
    public bool CapturedKeystrokes { get; set; }

    /// <summary>Seconds the webcam recording started after the screen recording (PiP sync).</summary>
    [JsonPropertyName("cameraStartOffset")]
    public double? CameraStartOffset { get; set; }

    /// <summary>Seconds the video's first frame lags the event-timeline clock (cursor alignment).</summary>
    [JsonPropertyName("eventTimeOffset")]
    public double? EventTimeOffset { get; set; }

    [JsonPropertyName("display")]
    public DisplayInfo Display { get; set; } = new();

    [JsonPropertyName("cursor")]
    public List<CursorSample> Cursor { get; set; } = new();

    [JsonPropertyName("clicks")]
    public List<ClickSample> Clicks { get; set; } = new();

    [JsonPropertyName("scrolls")]
    public List<ScrollSample> Scrolls { get; set; } = new();

    [JsonPropertyName("keys")]
    public List<KeySample> Keys { get; set; } = new();
}

public sealed class DisplayInfo
{
    [JsonPropertyName("pointWidth")] public double PointWidth { get; set; }
    [JsonPropertyName("pointHeight")] public double PointHeight { get; set; }
    [JsonPropertyName("pixelWidth")] public double PixelWidth { get; set; }
    [JsonPropertyName("pixelHeight")] public double PixelHeight { get; set; }
    [JsonPropertyName("scale")] public double Scale { get; set; } = 1;
}

/// <summary>Uniformly sampled cursor position (normalized, top-left origin).</summary>
public sealed class CursorSample
{
    [JsonPropertyName("t")] public double T { get; set; }
    [JsonPropertyName("x")] public double X { get; set; }
    [JsonPropertyName("y")] public double Y { get; set; }
}

public sealed class ClickSample
{
    [JsonPropertyName("t")] public double T { get; set; }
    [JsonPropertyName("x")] public double X { get; set; }
    [JsonPropertyName("y")] public double Y { get; set; }
    /// <summary>"left" | "right" | "other"</summary>
    [JsonPropertyName("button")] public string Button { get; set; } = "left";
}

public sealed class ScrollSample
{
    [JsonPropertyName("t")] public double T { get; set; }
    [JsonPropertyName("x")] public double X { get; set; }
    [JsonPropertyName("y")] public double Y { get; set; }
    [JsonPropertyName("dx")] public double Dx { get; set; }
    [JsonPropertyName("dy")] public double Dy { get; set; }
}

public sealed class KeySample
{
    [JsonPropertyName("t")] public double T { get; set; }
    [JsonPropertyName("keyCode")] public int KeyCode { get; set; }
    [JsonPropertyName("chars")] public string Chars { get; set; } = "";
    /// <summary>e.g. ["ctrl", "shift"] — normalized modifier names.</summary>
    [JsonPropertyName("modifiers")] public List<string> Modifiers { get; set; } = new();
}
