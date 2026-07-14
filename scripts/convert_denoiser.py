#!/usr/bin/env python3
"""Convert an ONNX spectral-mask denoiser to a Core ML model for DemoTape.

Produces a model matching the contract in scripts/DENOISER_MODEL.md:
  input : Float32 magnitude spectrum, length fftSize/2 (512 for fftSize 1024)
  output: Float32 per-bin gain in 0..1, same length

This runs OFFLINE on your dev machine (never at app runtime). It does not ship weights — you
supply the source ONNX model and verify its license before bundling the result.

Usage:
    pip install coremltools onnx numpy
    python3 scripts/convert_denoiser.py model.onnx Resources/Denoiser.mlpackage
"""
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    try:
        import coremltools as ct
    except ImportError:
        print("error: pip install coremltools onnx numpy", file=sys.stderr)
        return 1

    print(f"Converting {src} -> {dst}")
    # ONNX -> Core ML. Adjust input name/shape to your model if auto-detection isn't right;
    # DemoTape auto-discovers I/O names (first containing 'mag' / 'gain'|'mask').
    model = ct.converters.onnx.convert(model=src) if hasattr(ct.converters, "onnx") \
        else ct.convert(src)

    model.short_description = "DemoTape spectral-mask speech denoiser (magnitude -> gain 0..1)."
    model.save(dst)
    print(f"Saved {dst}")
    print("Next: compile if needed (xcrun coremlcompiler compile ...), then place at "
          "Resources/Denoiser.mlmodelc and run ./build-app.sh release.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
