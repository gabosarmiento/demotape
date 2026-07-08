using DemoTape.ViewModels;
using Xunit;

namespace DemoTape.Tests;

public class ShellViewModelTests
{
    private static ShellViewModel Build(
        out InMemorySettingsStore settings,
        out FakeRecordingController recording,
        out FakeNavigation nav,
        out RecordingInteraction interaction)
    {
        settings = new InMemorySettingsStore();
        recording = new FakeRecordingController();
        nav = new FakeNavigation();
        interaction = new RecordingInteraction();
        return new ShellViewModel(settings, new FakePathService(), recording, nav, interaction);
    }

    [Fact]
    public void InitialState_IsIdle_WithStartLabel()
    {
        var vm = Build(out _, out _, out _, out _);
        Assert.Equal(RecordingState.Idle, vm.State);
        Assert.True(vm.IsIdle);
        Assert.Equal("Start Recording", vm.StatusText);
    }

    [Fact]
    public async Task ToggleRecording_FlipsState_AndUpdatesStatus()
    {
        var vm = Build(out _, out var recording, out _, out _);
        await vm.ToggleRecordingCommand.ExecuteAsync(null);

        Assert.Equal(1, recording.ToggleCount);
        Assert.True(vm.IsRecording);
        Assert.Equal("Stop Recording", vm.StatusText);
    }

    [Fact]
    public void SettingToggles_PersistToStore()
    {
        var vm = Build(out var settings, out _, out _, out _);

        vm.CaptureMicrophone = false;
        vm.CaptureWebcam = true;
        vm.UseRegion = true;

        var saved = settings.Load();
        Assert.False(saved.CaptureMicrophone);
        Assert.True(saved.CaptureWebcam);
        Assert.True(saved.UseRegion);
    }

    [Fact]
    public void SelectFullScreen_ClearsRegion()
    {
        var vm = Build(out var settings, out _, out _, out _);
        vm.UseRegion = true;
        vm.SelectFullScreenCommand.Execute(null);

        Assert.False(vm.UseRegion);
        Assert.False(settings.Load().UseRegion);
    }

    [Fact]
    public void NavigationCommands_Delegate()
    {
        var vm = Build(out _, out _, out var nav, out _);
        vm.OpenWebPublishCommand.Execute(null);
        vm.OpenBackgroundPickerCommand.Execute(null);
        vm.OpenWebcamSettingsCommand.Execute(null);
        vm.SelectRecordingAreaCommand.Execute(null);

        Assert.Equal(1, nav.WebPublish);
        Assert.Equal(1, nav.Background);
        Assert.Equal(1, nav.Webcam);
        Assert.Equal(1, nav.Region);
    }

    [Fact]
    public void OpenRecordingsFolder_RevealsOutputDir()
    {
        var vm = Build(out _, out _, out _, out var interaction);
        vm.OpenRecordingsFolderCommand.Execute(null);
        Assert.Single(interaction.Revealed);
    }
}
