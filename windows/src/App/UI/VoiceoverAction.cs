using System.Text.Json;
using DemoTape.App.Infrastructure;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;
using DemoTape.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;

namespace DemoTape.App.UI;

/// <summary>
/// Builds the Voiceover action window: pick an ElevenLabs voice (with one-click preview), write or
/// reuse a script (pre-filled from the transcript), synthesize narration, and lay it over the video.
/// </summary>
public sealed class VoiceoverAction
{
    private readonly ISettingsStore _settings;
    private readonly IKeyStore _keys;
    private readonly IVoiceProvider _voices;
    private readonly IUserInteraction _interaction;
    private MediaPlayer? _previewPlayer;

    public VoiceoverAction(ISettingsStore settings, IKeyStore keys, IVoiceProvider voices, IUserInteraction interaction)
    {
        _settings = settings; _keys = keys; _voices = voices; _interaction = interaction;
    }

    public ActionPreviewWindow Create(string source)
    {
        var voiceCombo = new ComboBox { PlaceholderText = "Loading voices…", MinWidth = 260, IsEnabled = false };
        var previewButton = new Button { Content = "Preview voice", IsEnabled = false };
        var voiceRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        voiceRow.Children.Add(new TextBlock { Text = "Voice", Width = 70, VerticalAlignment = VerticalAlignment.Center });
        voiceRow.Children.Add(voiceCombo);
        voiceRow.Children.Add(previewButton);

        var scriptBox = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 110,
            MaxHeight = 180,
            PlaceholderText = "Write the narration script (or it pre-fills from your captions)…",
            IsSpellCheckEnabled = true,
        };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(voiceRow);
        panel.Children.Add(new TextBlock { Text = "Script", FontSize = 12, Opacity = 0.7 });
        panel.Children.Add(scriptBox);

        var voiceList = new List<Voice>();

        previewButton.Click += (_, _) =>
        {
            if (voiceCombo.SelectedIndex < 0 || voiceCombo.SelectedIndex >= voiceList.Count) return;
            var url = voiceList[voiceCombo.SelectedIndex].PreviewUrl;
            if (string.IsNullOrEmpty(url)) return;
            _previewPlayer ??= new MediaPlayer();
            _previewPlayer.Source = MediaSource.CreateFromUri(new Uri(url));
            _previewPlayer.Play();
        };

        async Task OnLoaded(ActionPreviewWindow w)
        {
            w.SetGenerateEnabled(false);
            // Pre-fill the script from a cached transcript, if any.
            var cached = LoadTranscript(w.SourcePath);
            if (cached is not null && scriptBox.Text.Length == 0)
                scriptBox.Text = VoiceoverPlanner.ScriptFromCues(cached);

            w.Note("Loading voices…");
            var key = _keys.Get(KeyAccounts.ElevenLabs) ?? "";
            var list = await _voices.ListVoicesAsync(key);
            voiceList.AddRange(list);
            foreach (var v in voiceList) voiceCombo.Items.Add(v.Label);
            if (voiceCombo.Items.Count > 0) voiceCombo.SelectedIndex = 0;
            voiceCombo.PlaceholderText = "Pick a voice";
            voiceCombo.IsEnabled = true;
            previewButton.IsEnabled = true;
            w.Note(voiceList.Count == 0 ? "No voices found for this key." : "");
            w.SetGenerateEnabled(voiceList.Count > 0);
        }

        async Task<string?> Render(string src, IProgress<double> progress, System.Threading.CancellationToken ct)
        {
            var script = scriptBox.Text.Trim();
            if (script.Length == 0 || voiceCombo.SelectedIndex < 0) return null;
            var voice = voiceList[voiceCombo.SelectedIndex];
            var key = _keys.Get(KeyAccounts.ElevenLabs) ?? "";

            progress.Report(0.1);
            var mp3 = await _voices.SynthesizeAsync(script, voice.Id, "eleven_multilingual_v2", key, ct);
            try
            {
                progress.Report(0.5);
                var (w, h) = await VideoSizeAsync(src, ct);
                var outPath = VoiceoverPlanner.OutputPath(src);
                await AiMedia.MuxNarrationAsync(src, mp3, outPath, w, h, ct);
                progress.Report(1.0);
                return outPath;
            }
            finally { TryDelete(mp3); }
        }

        var window = new ActionPreviewWindow("Voiceover", source, panel, Render, _interaction,
            nothingMessage: "Write a script and pick a voice first.", onLoaded: OnLoaded);
        window.Closed += (_, _) => { try { _previewPlayer?.Dispose(); } catch { } _previewPlayer = null; };
        return window;
    }

    private static async Task<(int w, int h)> VideoSizeAsync(string path, System.Threading.CancellationToken ct)
    {
        var file = await StorageFile.GetFileFromPathAsync(path).AsTask(ct);
        var props = await file.Properties.GetVideoPropertiesAsync().AsTask(ct);
        int w = (int)(props.Width == 0 ? 1280 : props.Width);
        int h = (int)(props.Height == 0 ? 720 : props.Height);
        return (w, h);
    }

    private static IReadOnlyList<CaptionCue>? LoadTranscript(string video)
    {
        try
        {
            var path = VoiceoverPlanner.TranscriptPath(video);
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<List<CaptionCue>>(File.ReadAllText(path));
        }
        catch { return null; }
    }

    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
}
