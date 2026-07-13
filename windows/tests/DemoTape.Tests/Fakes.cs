using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Models;
using DemoTape.Domain.Settings;
using DemoTape.ViewModels;

namespace DemoTape.Tests;

/// <summary>A transcoder that just writes placeholder files, so the orchestration is testable.</summary>
internal sealed class FakeTranscoder : IVideoTranscoder
{
    public List<(string input, string output, int height)> Calls { get; } = new();
    public int PosterCalls { get; private set; }

    public Task TranscodeAsync(string inputPath, string outputPath, int height,
        IProgress<double>? progress = null, CancellationToken ct = default)
    {
        Calls.Add((inputPath, outputPath, height));
        File.WriteAllText(outputPath, $"fake-{height}p");
        progress?.Report(1.0);
        return Task.CompletedTask;
    }

    public Task SavePosterAsync(string inputPath, string outputPath, int maxHeight, CancellationToken ct = default)
    {
        PosterCalls++;
        File.WriteAllText(outputPath, "fake-poster");
        return Task.CompletedTask;
    }

    public Task<double> GetDurationSecondsAsync(string inputPath, CancellationToken ct = default) => Task.FromResult(30.0);
}

internal sealed class InMemorySettingsStore : ISettingsStore
{
    private AppSettings _settings = new();
    public AppSettings Load() => _settings.Clone();
    public void Save(AppSettings settings) => _settings = settings.Clone();
}

internal sealed class FakeRecordingStore : IRecordingStore
{
    private readonly RecordingItem? _latest;
    public FakeRecordingStore(RecordingItem? latest) => _latest = latest;
    public IReadOnlyList<RecordingItem> ListStyledRecordings() => _latest is null ? Array.Empty<RecordingItem>() : new[] { _latest };
    public RecordingItem? LatestStyled() => _latest;
    public RecordingMetadata? LoadMetadata(string recordingPath) => null;
}

internal sealed class RecordingInteraction : IUserInteraction
{
    public List<string> Revealed { get; } = new();
    public List<(string title, string message)> Messages { get; } = new();
    public void RevealInExplorer(string path) => Revealed.Add(path);
    public Task ShowMessageAsync(string title, string message) { Messages.Add((title, message)); return Task.CompletedTask; }
}

internal sealed class FakePathService : IPathService
{
    public string OutputDirectory { get; init; } = Path.Combine(Path.GetTempPath(), "demotape-out");
    public string AppDataDirectory { get; init; } = Path.Combine(Path.GetTempPath(), "demotape-data");
}

internal sealed class FakeRecordingController : IRecordingController
{
    public RecordingState State { get; private set; } = RecordingState.Idle;
    public event Action<RecordingState>? StateChanged;
    public int ToggleCount { get; private set; }

    public int ArmFullScreenCount, ArmRegionCount, StartCount, StopCount, CancelCount;

    public Task ToggleAsync()
    {
        ToggleCount++;
        State = State == RecordingState.Idle ? RecordingState.Recording : RecordingState.Idle;
        StateChanged?.Invoke(State);
        return Task.CompletedTask;
    }

    public Task ArmFullScreenAsync() { ArmFullScreenCount++; Set(RecordingState.Armed); return Task.CompletedTask; }
    public Task ArmRegionAsync() { ArmRegionCount++; return Task.CompletedTask; }
    public Task StartAsync() { StartCount++; Set(RecordingState.Recording); return Task.CompletedTask; }
    public Task StopAsync() { StopCount++; Set(RecordingState.Idle); return Task.CompletedTask; }
    public Task CancelAsync() { CancelCount++; Set(RecordingState.Idle); return Task.CompletedTask; }

    private void Set(RecordingState s) { State = s; StateChanged?.Invoke(s); }
}

internal sealed class FakeNavigation : INavigationService
{
    public int WebPublish, Background, Webcam, AiSettings, Captions, Voiceover, Avatar;
    public void OpenWebPublish() => WebPublish++;
    public void OpenBackgroundPicker() => Background++;
    public void OpenWebcamSettings() => Webcam++;
    public void OpenAiSettings() => AiSettings++;
    public void GenerateCaptions() => Captions++;
    public void GenerateVoiceover() => Voiceover++;
    public void GenerateAvatar() => Avatar++;
}
