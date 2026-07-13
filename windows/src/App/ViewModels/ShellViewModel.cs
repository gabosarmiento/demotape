using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Settings;

namespace DemoTape.ViewModels;

/// <summary>
/// Backs the system-tray menu — the Windows equivalent of the macOS <c>AppDelegate</c> menu
/// bar. Holds the recording state, capture-mode / mic / webcam toggles (persisted), and
/// commands that delegate window-opening and capture to injected services (keeping this
/// unit-testable without any UI).
/// </summary>
public sealed partial class ShellViewModel : ObservableObject
{
    private readonly ISettingsStore _settingsStore;
    private readonly IPathService _paths;
    private readonly IRecordingController _recording;
    private readonly INavigationService _navigation;
    private readonly IUserInteraction _interaction;

    private AppSettings _settings;

    [ObservableProperty] private RecordingState _state;
    [ObservableProperty] private bool _useRegion;
    [ObservableProperty] private bool _captureMicrophone;
    [ObservableProperty] private bool _captureWebcam;

    public bool IsIdle => State == RecordingState.Idle;
    public bool IsRecording => State == RecordingState.Recording;

    public string StatusText => State switch
    {
        RecordingState.Idle => "Start Recording",
        RecordingState.Countdown => "Get ready…",
        RecordingState.Recording => "Stop Recording",
        RecordingState.Rendering => "Rendering…",
        _ => "Start Recording",
    };

    public ShellViewModel(
        ISettingsStore settingsStore,
        IPathService paths,
        IRecordingController recording,
        INavigationService navigation,
        IUserInteraction interaction)
    {
        _settingsStore = settingsStore;
        _paths = paths;
        _recording = recording;
        _navigation = navigation;
        _interaction = interaction;

        _settings = _settingsStore.Load();
        _useRegion = _settings.UseRegion;
        _captureMicrophone = _settings.CaptureMicrophone;
        _captureWebcam = _settings.CaptureWebcam;
        _state = _recording.State;

        _recording.StateChanged += s =>
        {
            State = s;
            OnPropertyChanged(nameof(IsIdle));
            OnPropertyChanged(nameof(IsRecording));
            OnPropertyChanged(nameof(StatusText));
        };
    }

    partial void OnStateChanged(RecordingState value)
    {
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(IsIdle));
        OnPropertyChanged(nameof(IsRecording));
    }

    /// <summary>
    /// Reloads the persisted toggles so the tray menu reflects changes made elsewhere (e.g. the
    /// region selector commits a region and flips <see cref="UseRegion"/> in settings directly).
    /// Call this when the menu is about to open.
    /// </summary>
    public void RefreshFromSettings()
    {
        _settings = _settingsStore.Load();
        UseRegion = _settings.UseRegion;
        CaptureMicrophone = _settings.CaptureMicrophone;
        CaptureWebcam = _settings.CaptureWebcam;
    }

    partial void OnUseRegionChanged(bool value) => Update(s => s.UseRegion = value);
    partial void OnCaptureMicrophoneChanged(bool value) => Update(s => s.CaptureMicrophone = value);
    partial void OnCaptureWebcamChanged(bool value) => Update(s => s.CaptureWebcam = value);

    private void Update(Action<AppSettings> mutate)
    {
        mutate(_settings);
        _settingsStore.Save(_settings);
    }

    [RelayCommand]
    private Task ToggleRecordingAsync() => _recording.ToggleAsync();

    [RelayCommand]
    private async Task SelectFullScreenAsync()
    {
        UseRegion = false;
        await _recording.ArmFullScreenAsync();
    }

    [RelayCommand]
    private Task SelectRecordingAreaAsync() => _recording.ArmRegionAsync();

    [RelayCommand]
    private void OpenWebPublish() => _navigation.OpenWebPublish();

    [RelayCommand]
    private void OpenBackgroundPicker() => _navigation.OpenBackgroundPicker();

    [RelayCommand]
    private void OpenWebcamSettings() => _navigation.OpenWebcamSettings();

    [RelayCommand]
    private void OpenAiSettings() => _navigation.OpenAiSettings();

    [RelayCommand]
    private void GenerateCaptions() => _navigation.GenerateCaptions();

    [RelayCommand]
    private void GenerateVoiceover() => _navigation.GenerateVoiceover();

    [RelayCommand]
    private void GenerateAvatar() => _navigation.GenerateAvatar();

    [RelayCommand]
    private void OpenRecordingsFolder() => _interaction.RevealInExplorer(_paths.OutputDirectory);
}
