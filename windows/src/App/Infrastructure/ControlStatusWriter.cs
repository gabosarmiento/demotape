using System.Text.Json;
using DemoTape.Domain.Abstractions;
using DemoTape.ViewModels;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Publishes DemoTape's recording state to a small, pollable <c>control.json</c>, the return channel
/// of the external control surface (mirrors the macOS <c>DemoControl.writeStatus</c>). An orchestrator
/// (e.g. the Playwright demo-driver) starts a take over a <c>demotape://</c> URL, then polls this file
/// for <c>state:"idle"</c> and reads <c>lastOutput</c> — the finished styled video.
///
/// <para>Written to <c>&lt;recordings&gt;\.demotape\control.json</c> (the Windows analogue of
/// <c>~/Movies/DemoTape/.demotape/control.json</c>), atomically so a poller never reads a half-file.</para>
/// </summary>
public sealed class ControlStatusWriter
{
    private readonly IPathService _paths;

    public ControlStatusWriter(IPathService paths) => _paths = paths;

    private string StatusPath
    {
        get
        {
            var dir = Path.Combine(_paths.OutputDirectory, ".demotape");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "control.json");
        }
    }

    /// <summary>Maps the internal state machine to the macOS-compatible status vocabulary.</summary>
    public static string StateName(RecordingState state) => state switch
    {
        RecordingState.Countdown => "countdown",
        RecordingState.Recording => "recording",
        RecordingState.Rendering => "rendering",
        _ => "idle",   // Idle and Armed both read as "idle" to a poller
    };

    /// <summary>Writes the current control state. Best-effort; never throws into a caller.</summary>
    public void Write(RecordingState state, string? lastOutput)
    {
        try
        {
            var dict = new Dictionary<string, object>
            {
                ["state"] = StateName(state),
                ["recording"] = state == RecordingState.Recording,
                ["updatedAt"] = DateTimeOffset.Now.ToString("O"),
            };
            if (!string.IsNullOrEmpty(lastOutput)) dict["lastOutput"] = lastOutput;

            var json = JsonSerializer.Serialize(dict, new JsonSerializerOptions { WriteIndented = true });
            var path = StatusPath;
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, path, overwrite: true);   // atomic swap
        }
        catch { /* status is advisory; failing to write it must never break recording */ }
    }
}
