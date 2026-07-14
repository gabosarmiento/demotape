using System.Text.Json;
using DemoTape.App.Infrastructure;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;
using DemoTape.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DemoTape.App.UI;

/// <summary>
/// Builds the Captions action window: transcribe the recording (cached after the first run), let the
/// user tweak the wording, then burn the captions in. Uses the shared <see cref="ActionPreviewWindow"/>.
/// </summary>
public sealed class CaptionsAction
{
    private readonly ISettingsStore _settings;
    private readonly IKeyStore _keys;
    private readonly ITranscriptionProvider _transcriber;
    private readonly CaptionBurner _burner;
    private readonly IUserInteraction _interaction;

    public CaptionsAction(ISettingsStore settings, IKeyStore keys, ITranscriptionProvider transcriber,
        CaptionBurner burner, IUserInteraction interaction)
    {
        _settings = settings; _keys = keys; _transcriber = transcriber; _burner = burner; _interaction = interaction;
    }

    public ActionPreviewWindow Create(string source)
    {
        var hint = new TextBlock { Text = "Transcript — edit any wording (one caption per line)", FontSize = 12, Opacity = 0.7 };
        var transcriptBox = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 130,
            MaxHeight = 200,
            PlaceholderText = "Transcribing…",
            IsSpellCheckEnabled = false,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(transcriptBox, ScrollBarVisibility.Auto);
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(hint);
        panel.Children.Add(transcriptBox);

        var cues = new List<CaptionCue>();

        async Task OnLoaded(ActionPreviewWindow w)
        {
            w.SetGenerateEnabled(false);
            var cached = LoadCache(w.SourcePath);
            if (cached is not null)
            {
                cues.AddRange(cached);
                transcriptBox.Text = Join(cues);
                w.Note($"Loaded cached transcript ({cues.Count} lines).");
                w.SetGenerateEnabled(true);
                return;
            }

            w.Note("Extracting audio…");
            var s = _settings.Load();
            var key = _keys.Get(KeyAccounts.Stt) ?? "";
            var audio = await AiMedia.ExtractAudioAsync(w.SourcePath);
            try
            {
                w.Note("Transcribing…");
                var result = await _transcriber.TranscribeAsync(audio, s.SttBaseUrl, s.SttModel, key, s.SttLanguage);
                cues.AddRange(result);
            }
            finally { TryDelete(audio); }

            SaveCache(w.SourcePath, cues);
            transcriptBox.Text = Join(cues);
            w.Note(cues.Count == 0 ? "No speech detected." : $"Transcribed {cues.Count} lines — edit if needed, then Generate.");
            w.SetGenerateEnabled(cues.Count > 0);
        }

        async Task<string?> Render(string src, IProgress<double> progress, System.Threading.CancellationToken ct)
        {
            var edited = ApplyEdits(cues, transcriptBox.Text);
            if (edited.Count == 0) return null;
            WriteSidecars(src, edited);
            SaveCache(src, edited);
            var outPath = VoiceoverPlanner.CaptionedPath(src);
            await _burner.BurnAsync(src, edited, outPath, progress, ct);
            return outPath;
        }

        return new ActionPreviewWindow("Captions", source, panel, Render, _interaction,
            nothingMessage: "No captions to burn — transcribe first.", onLoaded: OnLoaded);
    }

    // ---- transcript text <-> cues ----

    private static string Join(IReadOnlyList<CaptionCue> cues) => string.Join("\n", cues.Select(c => c.Text));

    /// <summary>Maps edited lines back onto the cues' timings by index (keeps original timing).</summary>
    private static List<CaptionCue> ApplyEdits(IReadOnlyList<CaptionCue> original, string edited)
    {
        var lines = edited.Replace("\r\n", "\n").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        var result = new List<CaptionCue>();
        for (int i = 0; i < lines.Count; i++)
        {
            if (i < original.Count) result.Add(original[i] with { Text = lines[i] });
            else result.Add(new CaptionCue(0, 0, lines[i]));
        }
        return result;
    }

    private void WriteSidecars(string video, IReadOnlyList<CaptionCue> cues)
    {
        try
        {
            var dir = Path.GetDirectoryName(video)!;
            var name = Path.GetFileNameWithoutExtension(video);
            File.WriteAllText(Path.Combine(dir, name + ".srt"), CaptionFormats.ToSrt(cues));
            File.WriteAllText(Path.Combine(dir, name + ".vtt"), CaptionFormats.ToVtt(cues));
        }
        catch { /* sidecars are a bonus */ }
    }

    private static List<CaptionCue>? LoadCache(string video)
    {
        try
        {
            var path = VoiceoverPlanner.TranscriptPath(video);
            if (!File.Exists(path)) return null;
            var cues = JsonSerializer.Deserialize<List<CaptionCue>>(File.ReadAllText(path));
            return cues is { Count: > 0 } ? cues : null;
        }
        catch { return null; }
    }

    private static void SaveCache(string video, IReadOnlyList<CaptionCue> cues)
    {
        try { File.WriteAllText(VoiceoverPlanner.TranscriptPath(video), JsonSerializer.Serialize(cues)); }
        catch { /* cache is best-effort */ }
    }

    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
}
