using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Small Media Foundation helpers shared by the AI actions: extract an audio track to a temp
/// <c>.m4a</c> (for transcription), and mux a narration track over a video (for voiceover).
/// </summary>
public static class AiMedia
{
    /// <summary>Exports the audio track of <paramref name="videoPath"/> to a temp .m4a. Throws if there's no audio.</summary>
    public static async Task<string> ExtractAudioAsync(string videoPath, CancellationToken ct = default)
    {
        var input = await StorageFile.GetFileFromPathAsync(videoPath).AsTask(ct).ConfigureAwait(false);
        var tempDir = ApplicationDataTempOrSystem();
        var folder = await StorageFolder.GetFolderFromPathAsync(tempDir).AsTask(ct).ConfigureAwait(false);
        var outName = $"demotape-{Guid.NewGuid():N}.m4a";
        var output = await folder.CreateFileAsync(outName, CreationCollisionOption.ReplaceExisting).AsTask(ct).ConfigureAwait(false);

        var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Medium);
        var transcoder = new MediaTranscoder();
        var prepared = await transcoder.PrepareFileTranscodeAsync(input, output, profile).AsTask(ct).ConfigureAwait(false);
        if (!prepared.CanTranscode)
            throw new InvalidOperationException($"Couldn't extract audio ({prepared.FailureReason}). The recording may have no audio track.");
        await prepared.TranscodeAsync().AsTask(ct).ConfigureAwait(false);
        return output.Path;
    }

    /// <summary>
    /// Produces <paramref name="outPath"/> with the picture of <paramref name="videoPath"/> and the
    /// narration audio laid over it from the start (the original audio is dropped). Re-encodes via
    /// MediaComposition (fine for short demo clips).
    /// </summary>
    public static async Task MuxNarrationAsync(string videoPath, string narrationPath, string outPath,
        int width, int height, CancellationToken ct = default)
    {
        var vFile = await StorageFile.GetFileFromPathAsync(videoPath).AsTask(ct).ConfigureAwait(false);
        var clip = await MediaClip.CreateFromFileAsync(vFile).AsTask(ct).ConfigureAwait(false);
        clip.Volume = 0; // drop the original audio — narration replaces it
        var comp = new MediaComposition();
        comp.Clips.Add(clip);

        var aFile = await StorageFile.GetFileFromPathAsync(narrationPath).AsTask(ct).ConfigureAwait(false);
        var track = await BackgroundAudioTrack.CreateFromFileAsync(aFile).AsTask(ct).ConfigureAwait(false);
        comp.BackgroundAudioTracks.Add(track);

        var outDir = Path.GetDirectoryName(outPath)!;
        var folder = await StorageFolder.GetFolderFromPathAsync(outDir).AsTask(ct).ConfigureAwait(false);
        var outFile = await folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting).AsTask(ct).ConfigureAwait(false);

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)Even(width);
        h264.Height = (uint)Even(height);
        h264.Bitrate = (uint)(Even(width) * Even(height) * 8);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264,
            Audio = AudioEncodingProperties.CreateAac(48000, 2, 128000),
        };
        var reason = await comp.RenderToFileAsync(outFile, MediaTrimmingPreference.Fast, profile).AsTask(ct).ConfigureAwait(false);
        if (reason != TranscodeFailureReason.None)
            throw new InvalidOperationException($"Couldn't attach the voiceover ({reason}).");
    }

    private static string ApplicationDataTempOrSystem()
    {
        try { return Windows.Storage.ApplicationData.Current.TemporaryFolder.Path; }
        catch { return Path.GetTempPath(); }
    }

    private static int Even(int v) => v <= 0 ? 2 : (v % 2 == 0 ? v : v - 1);
}
