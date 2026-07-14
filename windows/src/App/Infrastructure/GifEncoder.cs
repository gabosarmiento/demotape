using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Microsoft.Graphics.Canvas;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Streams;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Encodes a video to a looping animated GIF using the native GIF <see cref="BitmapEncoder"/> — no
/// third-party dependencies. Samples the source at a target fps via MediaPlayer frame-server and
/// scales to a target width. GIFs balloon fast, so length/width/fps are capped. Windows analogue of
/// the macOS <c>GifEncoder</c>.
/// </summary>
public sealed class GifEncoder : DemoTape.Domain.Abstractions.IGifEncoder
{
    public async Task EncodeAsync(string videoPath, string outPath, int maxWidth = 480, double fps = 10,
        double maxDuration = 15, CancellationToken ct = default)
    {
        var file = await StorageFile.GetFileFromPathAsync(videoPath).AsTask(ct);
        var vp = await file.Properties.GetVideoPropertiesAsync().AsTask(ct);
        int srcW = (int)(vp.Width == 0 ? 1280 : vp.Width), srcH = (int)(vp.Height == 0 ? 720 : vp.Height);
        double scale = Math.Min(1.0, maxWidth / (double)srcW);
        int outW = Even((int)(srcW * scale)), outH = Even((int)(srcH * scale));
        double interval = 1.0 / fps;

        var frames = new List<SoftwareBitmap>();
        using (var device = new CanvasDevice())
        using (var scaled = new CanvasRenderTarget(device, outW, outH, 96))
        using (var srcSurface = new CanvasRenderTarget(device, srcW, srcH, 96))
        {
            double lastEmitted = -1;
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
                    player.CopyFrameToVideoSurface(srcSurface);
                    double t = player.PlaybackSession.Position.TotalSeconds;
                    if (t > maxDuration) return;
                    if (t - lastEmitted < interval - 0.001) return;
                    lastEmitted = t;
                    using (var ds = scaled.CreateDrawingSession())
                        ds.DrawImage(srcSurface, new Rect(0, 0, outW, outH), new Rect(0, 0, srcW, srcH));
                    var bmp = SoftwareBitmap.CreateCopyFromBuffer(
                        scaled.GetPixelBytes().AsBuffer(), BitmapPixelFormat.Bgra8, outW, outH, BitmapAlphaMode.Ignore);
                    lock (frames) { if (frames.Count < 600) frames.Add(bmp); }
                }
                catch { }
            };
            player.Source = MediaSource.CreateFromStorageFile(file);
            await opened.Task;
            player.Play();
            await ended.Task;
            await Task.Delay(120);
            player.Dispose();
        }

        if (frames.Count == 0) throw new InvalidOperationException("No frames sampled for the GIF.");

        var outDir = Path.GetDirectoryName(outPath)!;
        var folder = await StorageFolder.GetFolderFromPathAsync(outDir).AsTask(ct);
        var outFile = await folder.CreateFileAsync(Path.GetFileName(outPath), CreationCollisionOption.ReplaceExisting).AsTask(ct);
        using (var stream = await outFile.OpenAsync(FileAccessMode.ReadWrite))
        {
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.GifEncoderId, stream);
            // Loop forever (NETSCAPE2.0 application extension).
            await encoder.BitmapProperties.SetPropertiesAsync(new BitmapPropertySet
            {
                { "/appext/application", new BitmapTypedValue(Encoding.ASCII.GetBytes("NETSCAPE2.0"), Windows.Foundation.PropertyType.UInt8Array) },
                { "/appext/data", new BitmapTypedValue(new byte[] { 3, 1, 0, 0 }, Windows.Foundation.PropertyType.UInt8Array) },
            });

            ushort delay = (ushort)Math.Max(2, Math.Round(100.0 / fps)); // hundredths of a second
            for (int i = 0; i < frames.Count; i++)
            {
                encoder.SetSoftwareBitmap(frames[i]);
                await encoder.BitmapProperties.SetPropertiesAsync(new BitmapPropertySet
                {
                    { "/grctlext/Delay", new BitmapTypedValue(delay, Windows.Foundation.PropertyType.UInt16) },
                });
                if (i < frames.Count - 1) await encoder.GoToNextFrameAsync();
            }
            await encoder.FlushAsync();
        }
        foreach (var f in frames) f.Dispose();
    }

    private static int Even(int v) => v % 2 == 0 ? v : v - 1;
}
