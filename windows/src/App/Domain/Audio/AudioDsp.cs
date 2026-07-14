namespace DemoTape.Domain.Audio;

/// <summary>A minimal RBJ-cookbook biquad (Direct Form I). Ported from the macOS <c>Biquad</c>.</summary>
public struct Biquad
{
    private float _b0, _b1, _b2, _a1, _a2;
    private float _x1, _x2, _y1, _y2;

    public float Process(float x)
    {
        float y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
        _x2 = _x1; _x1 = x; _y2 = _y1; _y1 = y;
        return y;
    }

    public static Biquad HighPass(double sr, float freq, float q)
    {
        float w0 = 2 * MathF.PI * freq / (float)sr, cs = MathF.Cos(w0), sn = MathF.Sin(w0), alpha = sn / (2 * q), a0 = 1 + alpha;
        return new Biquad { _b0 = (1 + cs) / 2 / a0, _b1 = -(1 + cs) / a0, _b2 = (1 + cs) / 2 / a0, _a1 = -2 * cs / a0, _a2 = (1 - alpha) / a0 };
    }

    public static Biquad Peaking(double sr, float freq, float q, float gainDb)
    {
        float A = MathF.Pow(10, gainDb / 40), w0 = 2 * MathF.PI * freq / (float)sr, cs = MathF.Cos(w0), sn = MathF.Sin(w0), alpha = sn / (2 * q), a0 = 1 + alpha / A;
        return new Biquad { _b0 = (1 + alpha * A) / a0, _b1 = -2 * cs / a0, _b2 = (1 - alpha * A) / a0, _a1 = -2 * cs / a0, _a2 = (1 - alpha / A) / a0 };
    }

    public static Biquad LowShelf(double sr, float freq, float gainDb)
    {
        float A = MathF.Pow(10, gainDb / 40), w0 = 2 * MathF.PI * freq / (float)sr, cs = MathF.Cos(w0), sn = MathF.Sin(w0);
        float alpha = sn / 2 * MathF.Sqrt((A + 1 / A) * (1 / 0.9f - 1) + 2), sqrtA = MathF.Sqrt(A);
        float a0 = (A + 1) + (A - 1) * cs + 2 * sqrtA * alpha;
        return new Biquad
        {
            _b0 = A * ((A + 1) - (A - 1) * cs + 2 * sqrtA * alpha) / a0,
            _b1 = 2 * A * ((A - 1) - (A + 1) * cs) / a0,
            _b2 = A * ((A + 1) - (A - 1) * cs - 2 * sqrtA * alpha) / a0,
            _a1 = -2 * ((A - 1) + (A + 1) * cs) / a0,
            _a2 = ((A + 1) + (A - 1) * cs - 2 * sqrtA * alpha) / a0,
        };
    }
}

/// <summary>
/// "Studio voice" enhancement + a tunable noise gate — offline, on-device, dependency-free. Ported
/// from the macOS <c>VoiceEnhancer</c> (EQ + compressor + normalize) with a time-domain gate standing
/// in for the STFT spectral denoiser (per the Windows catch-up plan). All pure/testable.
/// </summary>
public static class AudioDsp
{
    /// <summary>Studio-voice chain per channel, then joint normalize with a soft ceiling.</summary>
    public static float[][] Enhance(float[][] channels, double sampleRate)
    {
        if (sampleRate <= 0) return channels;
        var outCh = channels.Select(c => EnhanceChannel(c, sampleRate)).ToArray();

        float peak = 0;
        foreach (var ch in outCh) foreach (var v in ch) peak = MathF.Max(peak, MathF.Abs(v));
        if (peak > 0.02f)
        {
            float gain = MathF.Min(0.9f / peak, 4f);
            foreach (var ch in outCh) for (int i = 0; i < ch.Length; i++) ch[i] = SoftClip(ch[i] * gain);
        }
        return outCh;
    }

    private static float[] EnhanceChannel(float[] input, double sr)
    {
        if (input.Length <= 4) return input;
        var hp = Biquad.HighPass(sr, 85, 0.707f);
        var warmth = Biquad.LowShelf(sr, 200, 1.5f);
        var presence = Biquad.Peaking(sr, 5000, 0.9f, 3.0f);
        var x = (float[])input.Clone();
        for (int i = 0; i < x.Length; i++) x[i] = presence.Process(warmth.Process(hp.Process(x[i])));
        return Compress(x, sr);
    }

    private static float[] Compress(float[] input, double sr)
    {
        const float thresholdDb = -24, ratio = 3, attack = 0.005f, release = 0.15f;
        float attackCoef = MathF.Exp(-1f / (attack * (float)sr));
        float releaseCoef = MathF.Exp(-1f / (release * (float)sr));
        float makeupDb = -thresholdDb * (1 - 1 / ratio) * 0.5f;
        float env = MathF.Abs(input.Length > 0 ? input[0] : 0);
        var outp = new float[input.Length];
        for (int i = 0; i < input.Length; i++)
        {
            float level = MathF.Abs(input[i]);
            env = level > env ? attackCoef * env + (1 - attackCoef) * level : releaseCoef * env + (1 - releaseCoef) * level;
            float envDb = 20 * MathF.Log10(MathF.Max(env, 1e-9f));
            float gainDb = envDb > thresholdDb ? (thresholdDb - envDb) * (1 - 1 / ratio) : 0;
            float gain = MathF.Min(MathF.Pow(10, (gainDb + makeupDb) / 20), 4);
            outp[i] = input[i] * gain;
        }
        return outp;
    }

    private static float SoftClip(float x)
    {
        const float t = 0.9f;
        float a = MathF.Abs(x);
        if (a <= t) return x;
        return (x < 0 ? -1 : 1) * (t + (1 - t) * MathF.Tanh((a - t) / (1 - t)));
    }

    /// <summary>
    /// Downward noise gate: learns a per-clip noise floor from the quietest windows, then attenuates
    /// windows near/below it (smoothed to avoid pumping). Removes steady room tone/hiss in gaps.
    /// <paramref name="strength"/> 0..1 controls attenuation depth.
    /// </summary>
    public static float[] NoiseGate(float[] input, double sampleRate, double strength,
        int windowSamples = 0)
    {
        float s = (float)Math.Clamp(strength, 0, 1);
        if (s <= 0 || input.Length < 16) return input;
        int win = windowSamples > 0 ? windowSamples : Math.Max(64, (int)(sampleRate * 0.02)); // 20 ms

        int count = (input.Length + win - 1) / win;
        var rms = new float[count];
        for (int w = 0; w < count; w++)
        {
            int start = w * win, n = Math.Min(win, input.Length - start);
            double sum = 0;
            for (int k = 0; k < n; k++) { float v = input[start + k]; sum += v * v; }
            rms[w] = (float)Math.Sqrt(sum / Math.Max(1, n));
        }

        // Noise floor = 15th percentile of window RMS; gate opens ~6 dB above it.
        var sorted = (float[])rms.Clone();
        Array.Sort(sorted);
        float floor = sorted[Math.Clamp((int)(count * 0.15), 0, count - 1)];
        float openThresh = floor * 2.0f;                 // +6 dB
        float closedGain = (1 - s) + s * 0.06f;          // residual gain when fully gated

        var outp = new float[input.Length];
        float gain = 1f;
        // Per-sample gain ramped toward each window's target (attack/release smoothing).
        float attack = MathF.Exp(-1f / (0.005f * (float)sampleRate));
        float release = MathF.Exp(-1f / (0.08f * (float)sampleRate));
        for (int w = 0; w < count; w++)
        {
            float target = rms[w] >= openThresh ? 1f : closedGain;
            int start = w * win, n = Math.Min(win, input.Length - start);
            for (int k = 0; k < n; k++)
            {
                float coef = target < gain ? release : attack;
                gain = coef * gain + (1 - coef) * target;
                outp[start + k] = input[start + k] * gain;
            }
        }
        return outp;
    }
}
