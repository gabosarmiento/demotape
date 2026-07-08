using DemoTape.ViewModels;
using Microsoft.Extensions.Logging;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Placeholder recording controller for the capture + auto-render pipeline, which is planned
/// as a later vertical slice (Windows.Graphics.Capture + Win2D). It is intentionally NOT a
/// removed feature — the abstraction, state machine, and wiring are in place so the pipeline
/// can be dropped in without touching the shell. For now it explains what's coming.
/// </summary>
public sealed class DeferredRecordingController : IRecordingController
{
    private readonly IUserInteraction _interaction;
    private readonly ILogger<DeferredRecordingController> _logger;

    public RecordingState State { get; private set; } = RecordingState.Idle;
    public event Action<RecordingState>? StateChanged;

    public DeferredRecordingController(IUserInteraction interaction, ILogger<DeferredRecordingController> logger)
    {
        _interaction = interaction;
        _logger = logger;
    }

    public async Task ToggleAsync()
    {
        _logger.LogInformation("Record toggle requested (capture pipeline not yet implemented)");
        await _interaction.ShowMessageAsync(
            "Screen capture is coming next",
            "The Windows.Graphics.Capture + Win2D recording/auto-render pipeline is the next vertical " +
            "slice. This build ships the full app shell, settings, and the end-to-end Web Publish flow. " +
            "Use \"Web Publish Latest…\" on an existing styled .mp4 to try the encode pipeline.");
    }
}
