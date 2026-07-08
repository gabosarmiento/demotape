using DemoTape.Domain.Abstractions;
using DemoTape.Services;
using DemoTape.ViewModels;
using Xunit;

namespace DemoTape.Tests;

public class WebPublishViewModelTests : IDisposable
{
    private readonly string _tempDir;

    public WebPublishViewModelTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "demotape-vm-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
    }

    private WebPublishViewModel BuildVm(RecordingItem? latest, out RecordingInteraction interaction)
    {
        interaction = new RecordingInteraction();
        var transcoder = new FakeTranscoder();
        return new WebPublishViewModel(
            new FakeRecordingStore(latest),
            new WebPublishService(transcoder),
            new InMemorySettingsStore(),
            interaction);
    }

    [Fact]
    public void LoadLatest_NoRecording_DisablesExport()
    {
        var vm = BuildVm(null, out _);
        vm.LoadLatest();

        Assert.False(vm.HasSource);
        Assert.False(vm.ExportCommand.CanExecute(null));
        Assert.Contains("No styled recording", vm.SourceName);
    }

    [Fact]
    public void Tiers_DefaultTo540_FromSettings()
    {
        var vm = BuildVm(null, out _);
        var selected = vm.Tiers.Where(t => t.IsSelected).Select(t => t.Height).ToList();
        Assert.Equal(new[] { 540 }, selected);
    }

    [Fact]
    public void Estimate_UpdatesWhenTierToggled()
    {
        var source = new RecordingItem(Path.Combine(_tempDir, "a.styled.mp4"), "a.styled.mp4", DateTimeOffset.Now, 30);
        var vm = BuildVm(source, out _);
        vm.LoadLatest();

        var before = vm.Estimate;
        vm.Tiers.First(t => t.Height == 720).IsSelected = true;
        Assert.NotEqual(before, vm.Estimate);
        Assert.Contains("720p", vm.Estimate);
    }

    [Fact]
    public async Task Export_PublishesAndRevealsFolder()
    {
        var sourcePath = Path.Combine(_tempDir, "a.styled.mp4");
        File.WriteAllText(sourcePath, "master");
        var source = new RecordingItem(sourcePath, "a.styled.mp4", DateTimeOffset.Now, 30);
        var vm = BuildVm(source, out var interaction);
        vm.LoadLatest();

        await vm.ExportCommand.ExecuteAsync(null);

        Assert.Single(interaction.Revealed);
        Assert.True(Directory.Exists(interaction.Revealed[0]));
        Assert.False(vm.IsExporting);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }
}
