"""Reproduces Orator's published speech model: Parakeet TDT 0.6B v3 with an 8-bit encoder.

Usage: runtime/.venv/bin/python scripts/quantize_model.py <full-precision-model-dir> <output-dir>
The input is mlx-community/parakeet-tdt-0.6b-v3 at revision ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15.
"""
import json
import sys
from pathlib import Path

import mlx.nn as nn
from parakeet_mlx import from_pretrained

QUANTIZATION = {"bits": 8, "group_size": 64, "strategy": "encoder_only"}


def main(source, output):
    source, output = Path(source), Path(output)
    model = from_pretrained(str(source))
    # The encoder holds most of the weights and tolerates 8-bit well; the small decoder and joint
    # network stay in bfloat16, which keeps transcripts identical on the benchmark set.
    nn.quantize(model.encoder, group_size=QUANTIZATION["group_size"], bits=QUANTIZATION["bits"])
    output.mkdir(parents=True, exist_ok=True)
    model.save_weights(str(output / "model.safetensors"))
    config = json.loads((source / "config.json").read_text())
    config["quantization"] = QUANTIZATION
    (output / "config.json").write_text(json.dumps(config))


if __name__ == "__main__":
    main(*sys.argv[1:3])
