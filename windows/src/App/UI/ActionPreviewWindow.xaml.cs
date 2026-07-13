using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DemoTape.Domain.Abstractions;
using DemoTape.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// A focused post-recording action window — the Windows analogue of the macOS ActionPreviewController:
/// Source and Result players side by side, subclass-supplied controls, a single "Generate preview"
/// button, progress, and a Reveal link. Reusable across Captions / Voiceover / Avatar / Auto-Cut /
/// Templates: pass a title, the source clip, optional controls, and an async render delegate.
/// </summary>
public sealed partial class ActionPreviewWindow : Window
{
    /// <summary>Render the action for the given source. Return the output path, or null when there's
    /// nothing to produce (the window shows <c>nothingMessage</c>). Throw to report an error.</summary>
    public delegate Task<string?> RenderDelegate(string source, IProgress<double> progress, CancellationToken ct);

    private readonly RenderDelegate _render;
    private readonly IUserInteraction _interaction;
    private readonly string _nothingMessage;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly CancellationTokenSource _cts = new();

    private string _source;
    private string? _lastResult;

    public ActionPreviewWindow(string title, string source, FrameworkElement? controls,
        RenderDelegate render, IUserInteraction interaction, string nothingMessage = "Nothing to generate.")
    {
        _source = source;
        _render = render;
        _interaction = interaction;
        _nothingMessage = nothingMessage;
        InitializeComponent();

        Title = title;
        if (controls is not null) ControlsHost.Child = controls;
        Closed += (_, _) => { _cts.Cancel(); StopPlayers(); };
        ReloadSource();
    }

    private void ReloadSource()
    {
        SourceName.Text = Path.GetFileName(_source);
        LoadInto(SourcePlayer, _source);
    }

    private static void LoadInto(MediaPlayerElement view, string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) { view.Source = null; return; }
        view.Source = MediaSource.CreateFromUri(new Uri(path));
    }

    private async void OnChangeSource(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".mp4");
        picker.FileTypeFilter.Add(".mov");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        _source = file.Path;
        _lastResult = null;
        ResultRow.Visibility = Visibility.Collapsed;
        ResultPlayer.Source = null;
        ResultBadge.Text = "not generated yet";
        Message.Text = "";
        ReloadSource();
    }

    private async void OnGenerate(object sender, RoutedEventArgs e)
    {
        GenerateButton.IsEnabled = false;
        Busy.IsActive = true;
        ResultRow.Visibility = Visibility.Collapsed;
        Message.Text = "";
        var progress = new Progress<double>(p => _dispatcher.TryEnqueue(() => Message.Text = $"Rendering… {(int)(p * 100)}%"));
        try
        {
            var outPath = await _render(_source, progress, _cts.Token);
            if (outPath is not null && File.Exists(outPath))
            {
                _lastResult = outPath;
                LoadInto(ResultPlayer, outPath);
                ResultBadge.Text = Path.GetFileName(outPath);
                ResultLink.Text = Path.GetFileName(outPath);
                ResultRow.Visibility = Visibility.Visible;
                Message.Text = "";
            }
            else Message.Text = _nothingMessage;
        }
        catch (OperationCanceledException) { /* window closing */ }
        catch (Exception ex) { Message.Text = ex.Message; }
        finally
        {
            Busy.IsActive = false;
            GenerateButton.IsEnabled = true;
        }
    }

    private void OnReveal(object sender, RoutedEventArgs e)
    {
        if (_lastResult is not null) _interaction.RevealInExplorer(_lastResult);
    }

    private void StopPlayers()
    {
        try { SourcePlayer.MediaPlayer?.Pause(); } catch { }
        try { ResultPlayer.MediaPlayer?.Pause(); } catch { }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
