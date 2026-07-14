# Neural noise-suppression model (Core ML)

DemoTape's **Smart Noise Suppression** toggle runs an on-device neural denoiser when a compatible
Core ML model is bundled, and falls back to the built-in DSP reducer when it isn't. This document
is the contract for producing that model. Nothing here ships a model — you generate one and drop
it in.

## Where the model goes

Place the compiled model in `Resources/` named exactly:

```
Resources/Denoiser.mlmodelc      (compiled — preferred)
# or
Resources/Denoiser.mlpackage
```

`build-app.sh` copies `Resources/` into the app bundle, so `CoreMLSpeechEnhancer` finds it at
runtime. With no model present, the app uses the DSP reducer (current behaviour) — zero change.

## Tensor contract

`CoreMLSpeechEnhancer` runs its own STFT (fftSize 1024, hop 256, 48 kHz) and calls the model
**once per frame** with the magnitude spectrum, expecting a per-bin gain mask back:

| role   | name (auto-detected)                          | shape        | dtype   | range |
|--------|-----------------------------------------------|--------------|---------|-------|
| input  | first name containing `mag` (else first input) | `[512]`      | Float32 | ≥ 0   |
| output | first name containing `gain`/`mask` (else first) | `[512]`    | Float32 | 0…1   |

`512 = fftSize/2`. The Swift side multiplies the complex spectrum by the returned gain and
resynthesises with overlap-add. Keep the STFT config in `CoreMLSpeechEnhancer` and the model's
training config identical, or change both together.

> Note: this is the classic **spectral-mask** interface (magnitude → gain). RNNoise/DTLN-style
> models map onto it directly. **DeepFilterNet** is stronger on fan-under-speech but does not fit
> this interface as-is — its ERB analysis + deep-filtering front/back-end would need porting (a
> larger, separate effort). Recommend validating the pipeline with a mask-style model first, then
> deciding whether DFN's extra quality justifies the front-end port.

## Conversion recipe (coremltools)

Run in a Python venv on any machine (not needed at app runtime):

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install coremltools onnx numpy
python3 scripts/convert_denoiser.py path/to/model.onnx Resources/Denoiser.mlpackage
```

If your source model is stateful (per-frame LSTM/GRU) or uses a different frame size, export a
**stateless magnitude→gain** variant matching the table above (many repos provide this), or adapt
`CoreMLSpeechEnhancer` to thread recurrent state.

## Licensing

Only bundle a model whose license permits redistribution. RNNoise is BSD; DTLN is MIT;
DeepFilterNet code is MIT/Apache-2.0 — verify the specific **weights'** terms before shipping.
