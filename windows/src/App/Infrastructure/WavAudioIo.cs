using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Dependency-free PCM audio I/O for the on-device DSP: decode a media file's audio to mono float
/// samples (via a MediaTranscoder WAV round-trip) and encode processed samples back to AAC/.m4a.
/// </summary>
public static class WavAudioIo
{
    /// <summary>Decodes the audio track of <paramref name="mediaPath"/> to mono float samples at <paramref name="sampleRate"/>.</summary>
    public static async Task<(float[] samples, int sampleRate)> ExtractMonoAsync(string mediaPath, int sampleRate, CancellationToken ct = default)
    {
        var wav = Path.Combine(Path.GetTempPath(), $"demotape-pcm-{Guid.NewGuid():N}.wav");
        try
        {
            var input = await StorageFile.GetFileFromPathAsync(mediaPath).AsTask(ct).ConfigureAwait(false);
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(wav)!).AsTask(ct).ConfigureAwait(false);
            var outFile = await folder.CreateFileAsync(Path.GetFileName(wav), CreationCollisionOption.ReplaceExisting).AsTask(ct).ConfigureAwait(false);

            var profile = MediaEncodingProfile.CreateWav(AudioEncodingQuality.High);
            profile.Audio = AudioEncodingProperties.CreatePcm((uint)sampleRate, 1, 16);
            var transcoder = new MediaTranscoder();
            var prepared = await transcoder.PrepareFileTranscodeAsync(input, outFile, profile).AsTask(ct).ConfigureAwait(false);
            if (!prepared.CanTranscode)
                throw new InvalidOperationException($"Couldn't read audio ({prepared.FailureReason}). The recording may have no audio track.");
            await prepared.TranscodeAsync().AsTask(ct).ConfigureAwait(false);

            return ReadWavMono(outFile.Path);
        }
        finally { TryDelete(wav); }
    }

    /// <summary>Encodes mono float samples to an AAC .m4a at <paramref name="outM4aPath"/>.</summary>
    public static async Task EncodeMonoToM4aAsync(float[] samples, int sampleRate, string outM4aPath, CancellationToken ct = default)
    {
        var wav = Path.Combine(Path.GetTempPath(), $"demotape-pcm-{Guid.NewGuid():N}.wav");
        try
        {
            WriteWavMono(wav, samples, sampleRate);
            var input = await StorageFile.GetFileFromPathAsync(wav).AsTask(ct).ConfigureAwait(false);
            var outDir = Path.GetDirectoryName(outM4aPath)!;
            var folder = await StorageFolder.GetFolderFromPathAsync(outDir).AsTask(ct).ConfigureAwait(false);
            var outFile = await folder.CreateFileAsync(Path.GetFileName(outM4aPath), CreationCollisionOption.ReplaceExisting).AsTask(ct).ConfigureAwait(false);

            var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
            var transcoder = new MediaTranscoder();
            var prepared = await transcoder.PrepareFileTranscodeAsync(input, outFile, profile).AsTask(ct).ConfigureAwait(false);
            if (!prepared.CanTranscode) throw new InvalidOperationException($"Couldn't encode audio ({prepared.FailureReason}).");
            await prepared.TranscodeAsync().AsTask(ct).ConfigureAwait(false);
        }
        finally { TryDelete(wav); }
    }

    // ---- WAV (PCM 16-bit) helpers ----

    private static (float[] samples, int rate) ReadWavMono(string path)
    {
        var bytes = File.ReadAllBytes(path);
        // Find "fmt " and "data" chunks (skip RIFF header at 12).
        int pos = 12, sampleRate = 44100, channels = 1, bits = 16, dataOffset = -1, dataLen = 0;
        while (pos + 8 <= bytes.Length)
        {
            string id = System.Text.Encoding.ASCII.GetString(bytes, pos, 4);
            int size = BitConverter.ToInt32(bytes, pos + 4);
            int body = pos + 8;
            if (id == "fmt ")
            {
                channels = BitConverter.ToInt16(bytes, body + 2);
                sampleRate = BitConverter.ToInt32(bytes, body + 4);
                bits = BitConverter.ToInt16(bytes, body + 14);
            }
            else if (id == "data") { dataOffset = body; dataLen = size; break; }
            pos = body + size + (size & 1);
        }
        if (dataOffset < 0 || bits != 16) return (Array.Empty<float>(), sampleRate);

        int total = Math.Min(dataLen, bytes.Length - dataOffset) / 2;
        int frames = total / Math.Max(1, channels);
        var samples = new float[frames];
        for (int i = 0; i < frames; i++)
        {
            // Downmix to mono by averaging channels.
            int sum = 0;
            for (int c = 0; c < channels; c++) sum += BitConverter.ToInt16(bytes, dataOffset + (i * channels + c) * 2);
            samples[i] = sum / (float)channels / 32768f;
        }
        return (samples, sampleRate);
    }

    private static void WriteWavMono(string path, float[] samples, int sampleRate)
    {
        int dataLen = samples.Length * 2;
        using var fs = File.Create(path);
        using var bw = new BinaryWriter(fs);
        void Str(string s) => bw.Write(System.Text.Encoding.ASCII.GetBytes(s));
        Str("RIFF"); bw.Write(36 + dataLen); Str("WAVE");
        Str("fmt "); bw.Write(16); bw.Write((short)1); bw.Write((short)1);
        bw.Write(sampleRate); bw.Write(sampleRate * 2); bw.Write((short)2); bw.Write((short)16);
        Str("data"); bw.Write(dataLen);
        foreach (var f in samples)
        {
            int v = (int)MathF.Round(Math.Clamp(f, -1f, 1f) * 32767f);
            bw.Write((short)v);
        }
    }

    private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }
}
