using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Publishing;
using DemoTape.Domain.Settings;
using DemoTape.Services;
using Microsoft.Extensions.Logging;

namespace DemoTape.ViewModels;

/// <summary>
/// ViewModel for the Web Publish window (first vertical slice). Mirrors the macOS
/// <c>WebPublishController</c>: pick the latest styled recording, choose one or more quality
/// tiers, see a live size estimate, and export tiered web MP4s + poster + embed.
/// </summary>
public sealed partial class WebPublishViewModel : ObservableObject
{
    private readonly IRecordingStore _recordings;
    private readonly WebPublishService _publisher;
    private readonly ISettingsStore _settingsStore;
    private readonly IUserInteraction _interaction;
    private readonly ILogger<WebPublishViewModel> _logger;

    public ObservableCollection<TierSelection> Tiers { get; } = new();

    [ObservableProperty] private string _sourceName = "";
    [ObservableProperty] private string _estimate = "";
    [ObservableProperty] private bool _isExporting;
    [ObservableProperty] private double _progress;
    [ObservableProperty] private bool _hasSource;

    private RecordingItem? _source;

    public WebPublishViewModel(
        IRecordingStore recordings,
        WebPublishService publisher,
        ISettingsStore settingsStore,
        IUserInteraction interaction,
        ILogger<WebPublishViewModel>? logger = null)
    {
        _recordings = recordings;
        _publisher = publisher;
        _settingsStore = settingsStore;
        _interaction = interaction;
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

    /// <summary>Loads the latest styled recording as the publish source.</summary>
    public void LoadLatest()
    {
        _source = _recordings.LatestStyled();
        HasSource = _source is not null;
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
        if (_source is null) return;
        IsExporting = true;
        Progress = 0;
        ExportCommand.NotifyCanExecuteChanged();
        try
        {
            var progress = new Progress<double>(p => Progress = p);
            var result = await _publisher.PublishAsync(_source.StyledPath, SelectedHeights, progress);
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
}
