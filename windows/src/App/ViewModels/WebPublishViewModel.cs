using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DemoTape.Domain;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Publishing;
using DemoTape.Domain.Settings;
using DemoTape.Services;
using Microsoft.Extensions.Logging;

namespace DemoTape.ViewModels;

/// <summary>
/// ViewModel for the Web Publish window. Mirrors the macOS <c>WebPublishController</c>: pick the
/// best derivative (captioned > tight > voiceover > styled > raw via <see cref="RecordingLayout"/>),
/// choose quality tiers, see a live size estimate, and export tiered web MP4s + poster + embed.
/// After export completes, an "Open Folder" button appears so the user can reveal the output.
/// </summary>
public sealed partial class WebPublishViewModel : ObservableObject
{
    private readonly IRecordingStore _recordings;
    private readonly WebPublishService _publisher;
    private readonly ISettingsStore _settingsStore;
    private readonly IUserInteraction _interaction;
    private readonly IPathService? _paths;
    private readonly ILogger<WebPublishViewModel> _logger;

    public ObservableCollection<TierSelection> Tiers { get; } = new();

    [ObservableProperty] private string _sourceName = "";
    [ObservableProperty] private string _estimate = "";
    [ObservableProperty] private bool _isExporting;
    [ObservableProperty] private double _progress;
    [ObservableProperty] private bool _hasSource;

    /// <summary>Becomes true after a successful export, revealing the Open Folder button.</summary>
    [ObservableProperty] private bool _isFolderReady;

    private RecordingItem? _source;
    private string? _sourcePath;   // the file to publish (set by LoadLatest via source chaining)
    private string _outputDir = "";

    public WebPublishViewModel(
        IRecordingStore recordings,
        WebPublishService publisher,
        ISettingsStore settingsStore,
        IUserInteraction interaction,
        IPathService? paths = null,
        ILogger<WebPublishViewModel>? logger = null)
    {
        _recordings = recordings;
        _publisher = publisher;
        _settingsStore = settingsStore;
        _interaction = interaction;
        _paths = paths;
        _logger = logger ?? Microsoft.Extensions.Logging.Abstractions.NullLogger<WebPublishViewModel>.Instance;

        var settings = _settingsStore.Load();
        var selected = settings.PublishTiers.Where(WebPublishPlanner.Tiers.Contains).ToHashSet();
        if (selected.Count == 0) selected.Add(540);

        foreach (var tier in WebPublishPlanner.Tiers)
        {
            var t = new TierSelection(tier, selected.Contains(tier));
            t.SelectionChanged += (_, _) => OnTierToggled();
            Tiers.Add(t);
        }
    }

    /// <summary>
    /// Loads the best available source recording using source chaining: captioned > tight >
    /// voiceover > avatar > styled > raw. Falls back to <see cref="IRecordingStore.LatestStyled"/>
    /// when no path service is available.
    /// </summary>
    public void LoadLatest()
    {
        // Source chaining: use the highest-priority derivative in the output folder.
        if (_paths is not null)
        {
            var bestPath = RecordingLayout.LatestSource(_paths.OutputDirectory);
            if (bestPath is not null)
            {
                _sourcePath = bestPath;
                _source = null;
                HasSource = true;
                SourceName = Path.GetFileName(bestPath);
                UpdateEstimate();
                return;
            }
        }

        // Fallback: the recording store (existing behavior for tests / no path service).
        _source = _recordings.LatestStyled();
        _sourcePath = _source?.StyledPath;
        HasSource = _sourcePath is not null;
        SourceName = _source?.DisplayName ?? "No styled recording found — record something first.";
        UpdateEstimate();
    }

    private IReadOnlyCollection<int> SelectedHeights =>
        Tiers.Where(t => t.IsSelected).Select(t => t.Height).ToList();

    private void OnTierToggled()
    {
        var settings = _settingsStore.Load();
        settings.PublishTiers = SelectedHeights.OrderBy(h => h).ToList();
        _settingsStore.Save(settings);
        UpdateEstimate();
        ExportCommand.NotifyCanExecuteChanged();
    }

    private void UpdateEstimate()
    {
        double duration = _source?.DurationSeconds ?? 0;
        Estimate = WebPublishPlanner.EstimateSummary(duration, SelectedHeights);
    }

    private bool CanExport() => HasSource && !IsExporting && SelectedHeights.Count > 0;

    [RelayCommand(CanExecute = nameof(CanExport))]
    private async Task ExportAsync()
    {
        if (_sourcePath is null) return;
        IsExporting = true;
        IsFolderReady = false;
        Progress = 0;
        ExportCommand.NotifyCanExecuteChanged();
        try
        {
            var progress = new Progress<double>(p => Progress = p);
            var result = await _publisher.PublishAsync(_sourcePath, SelectedHeights, progress);
            _outputDir = result.OutputFolder;
            IsFolderReady = true;
            _interaction.RevealInExplorer(result.OutputFolder);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Web publish failed");
            await _interaction.ShowMessageAsync("Export failed", ex.Message);
        }
        finally
        {
            IsExporting = false;
            ExportCommand.NotifyCanExecuteChanged();
        }
    }

    /// <summary>Opens the export output folder in Explorer. Available once <see cref="IsFolderReady"/> is true.</summary>
    [RelayCommand]
    private void OpenFolder()
    {
        if (!string.IsNullOrEmpty(_outputDir))
            _interaction.RevealInExplorer(_outputDir);
    }
}
