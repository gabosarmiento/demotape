using DemoTape.App.Infrastructure;
using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Ai;
using DemoTape.Domain.Settings;
using DemoTape.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// Builds the Avatar Presenter action: turn the voiceover narration into a HeyGen presenter
/// (library avatar or your photo), lip-synced and composited into the webcam bubble → <c>…avatar.mp4</c>.
/// Paid — a cost estimate is confirmed first. Only the narration (and your photo, if used) is uploaded.
/// </summary>
public sealed class AvatarAction
{
    private readonly ISettingsStore _settings;
    private readonly IKeyStore _keys;
    private readonly IAvatarProvider _provider;
    private readonly AvatarCompositor _compositor;
    private readonly IUserInteraction _interaction;

    public AvatarAction(ISettingsStore settings, IKeyStore keys, IAvatarProvider provider,
        AvatarCompositor compositor, IUserInteraction interaction)
    {
        _settings = settings; _keys = keys; _provider = provider; _compositor = compositor; _interaction = interaction;
    }

    public ActionPreviewWindow Create(string source)
    {
        var sourceCombo = new ComboBox { MinWidth = 200 };
        sourceCombo.Items.Add("Library avatar");
        sourceCombo.Items.Add("Upload a photo…");
        sourceCombo.SelectedIndex = 1;

        var avatarCombo = new ComboBox { PlaceholderText = "Loading avatars…", MinWidth = 240, IsEnabled = false };
        var choosePhoto = new Button { Content = "Choose Photo…" };
        var photoLabel = new TextBlock { Text = "No photo chosen", Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
        var motionBox = new TextBox { PlaceholderText = "Optional motion prompt", MinWidth = 280 };
        var estimate = new TextBlock { FontSize = 12, Opacity = 0.85, TextWrapping = TextWrapping.Wrap };

        var avatarRow = Row("Library", avatarCombo);
        var photoRow = Row("Photo", choosePhoto, photoLabel);
        var motionRow = Row("Motion", motionBox);
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(Row("Avatar", sourceCombo));
        panel.Children.Add(avatarRow);
        panel.Children.Add(photoRow);
        panel.Children.Add(motionRow);
        panel.Children.Add(estimate);

        var avatars = new List<AvatarDescriptor>();
        string? photoPath = null;
        bool avatarsLoaded = false;
        ActionPreviewWindow? window = null;

        void SyncRows()
        {
            bool usePhoto = sourceCombo.SelectedIndex == 1;
            avatarRow.Visibility = usePhoto ? Visibility.Collapsed : Visibility.Visible;
            photoRow.Visibility = usePhoto ? Visibility.Visible : Visibility.Collapsed;
            motionRow.Visibility = usePhoto ? Visibility.Visible : Visibility.Collapsed;
        }
        sourceCombo.SelectionChanged += async (_, _) =>
        {
            SyncRows();
            if (sourceCombo.SelectedIndex == 0 && !avatarsLoaded) await LoadAvatars();
        };

        async Task LoadAvatars()
        {
            avatarsLoaded = true;
            window?.Note("Loading avatars…");
            try
            {
                var list = await _provider.ListAvatarsAsync(_keys.Get(KeyAccounts.HeyGen) ?? "");
                foreach (var a in list.Where(a => !a.IsPremium)) { avatars.Add(a); avatarCombo.Items.Add(a.Name); }
                if (avatarCombo.Items.Count > 0) avatarCombo.SelectedIndex = 0;
                avatarCombo.IsEnabled = true; avatarCombo.PlaceholderText = "Pick an avatar";
                window?.Note($"{avatars.Count} avatars available.");
            }
            catch (Exception ex) { avatarsLoaded = false; window?.Note("Couldn't load avatars: " + ex.Message); }
        }

        choosePhoto.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker();
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window!));
            picker.FileTypeFilter.Add(".png"); picker.FileTypeFilter.Add(".jpg"); picker.FileTypeFilter.Add(".jpeg");
            var file = await picker.PickSingleFileAsync();
            if (file is not null) { photoPath = file.Path; photoLabel.Text = file.Name; }
        };

        async Task OnLoaded(ActionPreviewWindow w)
        {
            SyncRows();
            double dur = await DurationAsync(w.SourcePath);
            estimate.Text = EstimateText(dur);
            if (!File.Exists(VoiceoverPlanner.NarrationPath(w.SourcePath)))
            {
                w.Note("No narration found — run Voiceover on this recording first, then generate the avatar.");
                w.SetGenerateEnabled(false);
            }
            else w.Note("Choose a photo or a library avatar, then Generate.");
        }

        async Task<string?> Render(string src, IProgress<double> progress, System.Threading.CancellationToken ct)
        {
            var narration = VoiceoverPlanner.NarrationPath(src);
            if (!File.Exists(narration))
                throw new InvalidOperationException("No narration found. Run Voiceover on this recording first.");

            bool usePhoto = sourceCombo.SelectedIndex == 1;
            if (usePhoto && photoPath is null) return null;
            if (!usePhoto && (avatars.Count == 0 || avatarCombo.SelectedIndex < 0)) return null;

            // Cost confirmation (uses HeyGen credits).
            var dlg = new ContentDialog
            {
                Title = "Generate avatar presenter?",
                Content = EstimateText(await DurationAsync(src)) +
                          "\n\nThis uses your HeyGen credits. Only the narration" + (usePhoto ? " and your photo" : "") +
                          " is uploaded — never your screen recording.",
                PrimaryButtonText = "Generate",
                CloseButtonText = "Cancel",
                XamlRoot = window!.Content.XamlRoot,
            };
            if (await dlg.ShowAsync() != ContentDialogResult.Primary) return null;

            var apiKey = _keys.Get(KeyAccounts.HeyGen) ?? "";
            AvatarSource avatarSource;
            bool chromaKey;
            if (usePhoto)
            {
                progress.Report(0.05); window?.Note("Uploading photo…");
                var imageAsset = await _provider.UploadAssetAsync(photoPath!, apiKey, ct);
                avatarSource = new AvatarSource.Photo(imageAsset);
                chromaKey = false; // photo avatars keep their background → passthrough into the circle
            }
            else
            {
                avatarSource = new AvatarSource.Library(avatars[avatarCombo.SelectedIndex].Id);
                chromaKey = true;  // library avatars render on a green background → key it out
            }

            progress.Report(0.15); window?.Note("Uploading narration…");
            var audioAsset = await _provider.UploadAssetAsync(narration, apiKey, ct);

            progress.Report(0.25); window?.Note("Generating avatar (a few minutes)…");
            var motion = motionBox.Text.Trim();
            var request = new AvatarGenerationRequest(avatarSource, audioAsset,
                Resolution: AvatarQuality.P720,
                MotionPrompt: usePhoto && motion.Length > 0 ? motion : null,
                Engine: usePhoto ? null : "avatar_iii");
            var job = await _provider.CreateVideoAsync(request, Guid.NewGuid().ToString(), apiKey, ct);

            // Poll with bounded backoff (up to ~15 min).
            string? resultUrl = null; double delay = 4, waited = 0;
            while (waited < 900)
            {
                ct.ThrowIfCancellationRequested();
                var status = await _provider.JobStatusAsync(job.Id, apiKey, ct);
                if (status is AvatarJobStatus.Completed c) { resultUrl = c.ResultUrl; break; }
                if (status is AvatarJobStatus.Failed f) throw new InvalidOperationException(f.Message);
                await Task.Delay(TimeSpan.FromSeconds(delay), ct);
                waited += delay; delay = Math.Min(delay * 1.5, 20);
                window?.Note($"Generating avatar… ({(int)waited}s)");
            }
            if (resultUrl is null) throw new InvalidOperationException("Avatar generation timed out.");

            progress.Report(0.8); window?.Note("Downloading…");
            var downloaded = Path.Combine(Path.GetTempPath(), $"demotape-avatar-{Guid.NewGuid():N}.mp4");
            await _provider.DownloadAsync(resultUrl, downloaded, ct);

            try
            {
                window?.Note("Compositing over your demo…");
                var s = _settings.Load();
                var outPath = VoiceoverPlanner.AvatarPath(src);
                await _compositor.ComposeAsync(src, downloaded, outPath,
                    s.WebcamPositionX, s.WebcamPositionY, s.WebcamSize, chromaKey, progress: progress, ct: ct);
                return outPath;
            }
            finally { TryDelete(downloaded); }
        }

        window = new ActionPreviewWindow("Avatar Presenter", source, panel, Render, _interaction,
            nothingMessage: "Pick a photo or avatar first.", onLoaded: OnLoaded);
        return window;
    }

    private static string EstimateText(double durationSeconds)
    {
        double mins = Math.Max(0.5, Math.Ceiling(durationSeconds / 30.0) * 0.5);
        int credits = (int)Math.Round(mins * 20);
        double dollars = credits * 0.05;
        var basis = $"Estimated ~{mins:0.0} min → ~{credits} HeyGen credits (~${dollars:0.00}). Rendering takes a few minutes.";
        if (durationSeconds > 120) return "⚠ Long clip — " + basis + " Best under ~2 min.";
        return basis;
    }

    private static async Task<double> DurationAsync(string path)
    {
        try
        {
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            var props = await file.Properties.GetVideoPropertiesAsync();
            return props.Duration.TotalSeconds;
        }
        catch { return 0; }
    }

    private static StackPanel Row(string label, params UIElement[] controls)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(new TextBlock { Text = label, Width = 70, VerticalAlignment = VerticalAlignment.Center });
        foreach (var c in controls) row.Children.Add(c);
        return row;
    }

    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
}
