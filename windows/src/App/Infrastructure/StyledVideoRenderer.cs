using System.Runtime.Versioning;
using DemoTape.Domain.Settings;
using Microsoft.Extensions.Logging;
using Windows.Media.Editing;
using Windows.Media.Effects;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Renders a raw screen capture + its event sidecar into DemoTape's auto-styled MP4, the Windows
/// analogue of the macOS <c>VideoRenderer</c>. It composes a <see cref="MediaComposition"/> with a
/// single clip carrying the <see cref="AutoZoomVideoEffect"/> (Win2D), then encodes H.264/AAC.
///
/// NOTE: a custom <c>IBasicVideoEffect</c> must be activatable by name. In an MSIX-packaged app
/// this is automatic; for the unpackaged build the effect type is registered via regfree WinRT
/// activation (see docs/BUILD.md). If activation is unavailable, the caller falls back to the raw
/// capture so recording never fails outright.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class StyledVideoRenderer
{
    private readonly ILogger<StyledVideoRenderer> _logger;

    public StyledVideoRenderer(ILogger<StyledVideoRenderer> logger) => _logger = logger;

    /// <summary>Renders <paramref name="rawPath"/> (+ its .events.json) to <paramref name="outPath"/>. Returns the styled path or null on failure.</summary>
    public async Task<string?> RenderAsync(string rawPath, string sidecarPath, string outPath, AppSettings settings)
    {
        try
        {
            var rawFile = await StorageFile.GetFileFromPathAsync(rawPath);
            var clip = await MediaClip.CreateFromFileAsync(rawFile);

            var props = new Windows.Foundation.Collections.PropertySet
            {
                ["sidecar"] = sidecarPath,
                ["maxZoom"] = 2.0,
                ["drawCursor"] = true,
                ["showBadges"] = settings.ShowShortcutBadges,
                ["showRipples"] = true,
            };
            var effect = new VideoEffectDefinition(typeof(AutoZoomVideoEffect).FullName, props);
            clip.VideoEffectDefinitions.Add(effect);

            var composition = new MediaComposition();
            composition.Clips.Add(clip);

            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
            profile.Video = VideoEncodingProperties.CreateH264();

            var outFolder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(outPath)!);
            var outFile = await outFolder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting);

            var result = await composition.RenderToFileAsync(outFile, MediaTrimmingPreference.Precise, profile);
            if (result != TranscodeFailureReason.None)
            {
                _logger.LogError("Styled render failed: {Reason}", result);
                return null;
            }
            _logger.LogInformation("Styled render complete -> {Name}", Path.GetFileName(outPath));
            return outPath;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Styled render threw; falling back to raw");
            return null;
        }
    }
}
