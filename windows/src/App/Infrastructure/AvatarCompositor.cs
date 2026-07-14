using System.Numerics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.UI;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.UI;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Composites a HeyGen avatar video into the webcam bubble over the styled recording. Library
/// (green-screen) avatars are chroma-keyed with a Win2D <see cref="ChromaKeyEffect"/>; photo avatars
/// are shown as-is. The screen's narration audio is preserved. Same frame-server + Win2D + remux
/// family as <see cref="CaptionBurner"/>/<see cref="StyledVideoRenderer"/>.
/// </summary>
public sealed class AvatarCompositor
{
    public async Task<string> ComposeAsync(string screenPath, string avatarPath, string outPath,
        double centerX, double centerY, double diameterFraction, bool chromaKey, string chromaHex = "#00B140",
        IProgress<double>? progress = null, CancellationToken ct = default)
    {
        var screenFile = await StorageFile.GetFileFromPathAsync(screenPath).AsTask(ct);
        var vp = await screenFile.Properties.GetVideoPropertiesAsync().AsTask(ct);
        int w = Even((int)(vp.Width == 0 ? 1280 : vp.Width));
        int h = Even((int)(vp.Height == 0 ? 720 : vp.Height));
        double duration = vp.Duration.TotalSeconds;
        var tempVideo = Path.Combine(Path.GetTempPath(), $"demotape-avatar-{Guid.NewGuid():N}.mp4");

        var key = ParseHex(chromaHex);
        var deviceLock = new object();

        using (var device = new CanvasDevice())
        using (var screenSurface = new CanvasRenderTarget(device, w, h, 96))
        using (var compRT = new CanvasRenderTarget(device, w, h, 96))
        using (var flipRT = new CanvasRenderTarget(device, w, h, 96))
        {
            // Secondary player: avatar frames into a surface, kept in sync-ish with the screen.
            var avatarFile = await StorageFile.GetFileFromPathAsync(avatarPath).AsTask(ct);
            var avp = await avatarFile.Properties.GetVideoPropertiesAsync().AsTask(ct);
            int aw = (int)(avp.Width == 0 ? 720 : avp.Width), ah = (int)(avp.Height == 0 ? 720 : avp.Height);
            using var avatarSurface = new CanvasRenderTarget(device, aw, ah, 96);
            bool avatarHasFrame = false;

            var avatarPlayer = new MediaPlayer { IsMuted = true, IsVideoFrameServerEnabled = true, IsLoopingEnabled = false };
            var avatarOpened = new TaskCompletionSource<bool>();
            avatarPlayer.MediaOpened += (_, _) => avatarOpened.TrySetResult(true);
            avatarPlayer.MediaFailed += (_, _) => avatarOpened.TrySetResult(true);
            avatarPlayer.VideoFrameAvailable += (_, _) =>
            {
                try { lock (deviceLock) { avatarPlayer.CopyFrameToVideoSurface(avatarSurface); avatarHasFrame = true; } }
                catch { }
            };
            avatarPlayer.Source = MediaSource.CreateFromStorageFile(avatarFile);
            await avatarOpened.Task;

            var channel = Channel.CreateBounded<(byte[] Bgra, TimeSpan Time)>(
                new BoundedChannelOptions(90) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
            var encodeTask = EncodeAsync(channel.Reader, w, h, tempVideo);

            var player = new MediaPlayer { IsMuted = true, IsVideoFrameServerEnabled = true, IsLoopingEnabled = false };
            var opened = new TaskCompletionSource<bool>();
            var ended = new TaskCompletionSource<bool>();
            player.MediaOpened += (_, _) => opened.TrySetResult(true);
            player.MediaFailed += (_, a) => { opened.TrySetException(new Exception(a.ErrorMessage)); ended.TrySetResult(true); };
            player.MediaEnded += (_, _) => ended.TrySetResult(true);

            player.VideoFrameAvailable += (_, _) =>
            {
                try
                {
                    lock (deviceLock)
                    {
                        player.CopyFrameToVideoSurface(screenSurface);
                        double t = player.PlaybackSession.Position.TotalSeconds;
                        using (var ds = compRT.CreateDrawingSession())
                        {
                            ds.DrawImage(screenSurface);
                            if (avatarHasFrame) DrawAvatar(ds, avatarSurface, w, h, centerX, centerY, diameterFraction, chromaKey, key);
                        }
                        using (var ds = flipRT.CreateDrawingSession())
                        {
                            ds.Transform = Matrix3x2.CreateScale(1, -1) * Matrix3x2.CreateTranslation(0, h);
                            ds.DrawImage(compRT);
                        }
                        channel.Writer.TryWrite((flipRT.GetPixelBytes(), TimeSpan.FromSeconds(t)));
                        if (duration > 0) progress?.Report(Math.Clamp(t / duration, 0, 0.95));
                    }
                }
                catch { }
            };

            player.Source = MediaSource.CreateFromStorageFile(screenFile);
            await opened.Task;
            avatarPlayer.Play();
            player.Play();
            await ended.Task;
            await Task.Delay(150);
            channel.Writer.Complete();
            await encodeTask;
            player.Dispose();
            avatarPlayer.Dispose();
        }

        // Preserve the screen's audio (the ElevenLabs narration) over the composited video.
        try
        {
            var audio = await AiMedia.ExtractAudioAsync(screenPath, ct);
            try { await AiMedia.MuxNarrationAsync(tempVideo, audio, outPath, w, h, ct); }
            finally { TryDelete(audio); }
            TryDelete(tempVideo);
        }
        catch
        {
            if (File.Exists(outPath)) TryDelete(outPath);
            File.Move(tempVideo, outPath);
        }
        progress?.Report(1.0);
        return outPath;
    }

    private static void DrawAvatar(CanvasDrawingSession ds, CanvasRenderTarget avatar, int w, int h,
        double centerX, double centerY, double diameterFraction, bool chromaKey, Color key)
    {
        double diameter = Math.Max(8, diameterFraction * w);
        float r = (float)(diameter / 2);
        var center = new Vector2((float)(centerX * w), (float)(centerY * h));

        Microsoft.Graphics.Canvas.ICanvasImage source = avatar;
        if (chromaKey)
            source = new ChromaKeyEffect { Source = avatar, Color = key, Tolerance = 0.30f, Feather = true };

        // Aspect-fill the avatar into the circle (cover), slight top bias for headroom.
        double aw = avatar.Size.Width, ah = avatar.Size.Height;
        double scale = Math.Max(diameter / aw, diameter / ah);
        double dw = aw * scale, dh = ah * scale;
        var dst = new Windows.Foundation.Rect(center.X - dw / 2, center.Y - dh / 2 - dh * 0.06, dw, dh);

        var srcRect = new Windows.Foundation.Rect(0, 0, aw, ah);
        using (ds.CreateLayer(1f, CanvasGeometry.CreateCircle(ds.Device, center, r)))
            ds.DrawImage(source, dst, srcRect);
        ds.DrawCircle(center, r, Color.FromArgb(230, 255, 255, 255), 3f);
        if (source is IDisposable d && !ReferenceEquals(source, avatar)) d.Dispose();
    }

    private static async Task EncodeAsync(ChannelReader<(byte[] Bgra, TimeSpan Time)> reader, int w, int h, string outPath)
    {
        var inProps = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)w, (uint)h);
        inProps.FrameRate.Numerator = 30; inProps.FrameRate.Denominator = 1;
        inProps.PixelAspectRatio.Numerator = 1; inProps.PixelAspectRatio.Denominator = 1;
        var mss = new MediaStreamSource(new VideoStreamDescriptor(inProps));
        mss.SampleRequested += async (_, e) =>
        {
            var deferral = e.Request.GetDeferral();
            try
            {
                if (await reader.WaitToReadAsync().ConfigureAwait(false) && reader.TryRead(out var f))
                {
                    var sample = MediaStreamSample.CreateFromBuffer(f.Bgra.AsBuffer(), f.Time);
                    sample.Duration = TimeSpan.FromSeconds(1.0 / 30);
                    e.Request.Sample = sample;
                }
                else e.Request.Sample = null;
            }
            finally { deferral.Complete(); }
        };

        var h264 = VideoEncodingProperties.CreateH264();
        h264.Width = (uint)w; h264.Height = (uint)h;
        h264.Bitrate = (uint)(w * h * 8);
        h264.FrameRate.Numerator = 30; h264.FrameRate.Denominator = 1;
        h264.PixelAspectRatio.Numerator = 1; h264.PixelAspectRatio.Denominator = 1;
        var profile = new MediaEncodingProfile
        {
            Container = new ContainerEncodingProperties { Subtype = MediaEncodingSubtypes.Mpeg4 },
            Video = h264, Audio = null,
        };
        var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(outPath)!);
        var file = await folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting);
        using var outStream = await file.OpenAsync(FileAccessMode.ReadWrite);
        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(mss, outStream, profile);
        if (!prepared.CanTranscode) throw new InvalidOperationException($"Avatar encode failed: {prepared.FailureReason}");
        await prepared.TranscodeAsync();
    }

    private static Color ParseHex(string hex)
    {
        var s = hex.TrimStart('#');
        if (s.Length != 6 || !int.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var v))
            return Color.FromArgb(255, 0, 0xB1, 0x40);
        return Color.FromArgb(255, (byte)((v >> 16) & 0xFF), (byte)((v >> 8) & 0xFF), (byte)(v & 0xFF));
    }

    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
