"""Private JSON-lines Parakeet worker. No server, telemetry, or runtime downloads."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
import wave

os.environ.update(
    HF_HUB_DISABLE_TELEMETRY="1",
    HF_HUB_DISABLE_IMPLICIT_TOKEN="1",
    DO_NOT_TRACK="1",
    TOKENIZERS_PARALLELISM="false",
)
MAX_SECONDS = 1200
SAMPLE_RATE = 16000
MAX_REQUEST = 65536


def emit(message):
    sys.__stdout__.write(json.dumps(message, ensure_ascii=False, allow_nan=False) + "\n")
    sys.__stdout__.flush()


def chunk_ranges(length, chunk=480000, overlap=32000):
    if chunk <= overlap or overlap < 0:
        raise ValueError("Invalid chunk overlap")
    start = 0
    while start < length:
        end = min(length, start + chunk)
        yield start, end
        if end == length:
            break
        start += chunk - overlap


def load_pcm(path, root):
    import numpy as np

    path = Path(path).resolve(strict=True)
    path.relative_to(root.resolve(strict=True))
    if not path.is_file() or path.stat().st_size > MAX_SECONDS * SAMPLE_RATE * 2 + 4096:
        raise ValueError("Recording exceeds size limit")
    if path.suffix == ".pcm":
        data = path.read_bytes()
        if len(data) % 2:
            raise ValueError("Truncated PCM sample")
    elif path.suffix == ".wav":
        with wave.open(str(path), "rb") as f:
            if (f.getnchannels(), f.getsampwidth(), f.getframerate(), f.getcomptype()) != (1, 2, SAMPLE_RATE, "NONE"):
                raise ValueError("Expected mono 16kHz PCM16 WAV")
            data = f.readframes(MAX_SECONDS * SAMPLE_RATE + 1)
    else:
        raise ValueError("Unsupported recording format")
    samples = np.frombuffer(data, dtype="<i2")
    if len(samples) > MAX_SECONDS * SAMPLE_RATE:
        raise ValueError("Recording exceeds duration limit")
    if len(samples) < 160:
        raise ValueError("Recording is too short")
    return samples.astype(np.float32) / 32768.0


def transcribe(model, audio, request_id):
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel
    from parakeet_mlx.alignment import (
        merge_longest_contiguous, merge_longest_common_subsequence,
        sentences_to_result, tokens_to_sentences,
    )
    if not audio.any():
        return ""
    tokens = []
    for start, end in chunk_ranges(len(audio)):
        if end - start < 160:
            break
        mel = get_logmel(mx.array(audio[start:end], dtype=mx.float32), model.preprocessor_config)
        part = model.generate(mel)[0]
        for token in part.tokens:
            token.start += start / SAMPLE_RATE
            token.end = token.start + token.duration
        if tokens:
            try:
                tokens = merge_longest_contiguous(tokens, part.tokens, overlap_duration=2.0)
            except RuntimeError:
                tokens = merge_longest_common_subsequence(tokens, part.tokens, overlap_duration=2.0)
        else:
            tokens = part.tokens
        emit({"event": "progress", "id": request_id, "fraction": end / len(audio)})
        del mel, part
        mx.clear_cache()
    return sentences_to_result(tokens_to_sentences(tokens)).text.strip()


# Parakeet TDT 0.6B v3 with an 8-bit encoder, quantized from mlx-community/parakeet-tdt-0.6b-v3 at
# revision ed2b7e8 by scripts/quantize_model.py. Transcripts match the full-precision model on the
# benchmark set while the download is 3.3x smaller. Pinned by size and SHA-256.
MODEL_SOURCE = "https://github.com/DevStrategist/orator/releases/download/speech-model-v1/"
MODEL_FILES = {
    "config.json": (235588, "06e1260568d5f4fb6f921fd24d6222cfa033af214b5e504f47b0e0db3599ec38"),
    "model.safetensors": (754851107, "e3745e51e513494c60494ce2ff61d49961823b3ce0333ff983bc6f83ddbbca45"),
}


def sha256(path):
    import hashlib

    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(url, target, size, digest):
    """Streams one file to a .partial sibling and moves it into place only once it verifies."""
    import urllib.request

    partial = target.with_name(target.name + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": "Orator"})
    with urllib.request.urlopen(request, timeout=60) as response, open(partial, "wb") as out:
        for block in iter(lambda: response.read(1 << 20), b""):
            out.write(block)
    if partial.stat().st_size != size or sha256(partial) != digest:
        partial.unlink(missing_ok=True)
        raise ValueError(f"Checksum mismatch for {target.name}")
    os.replace(partial, target)


def download(destination, source=MODEL_SOURCE):
    """One-time setup download. Reports JSON lines so the app can show progress."""
    destination = Path(destination).expanduser().resolve()
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    emit({"event": "size", "bytes": sum(size for size, _ in MODEL_FILES.values())})
    for name, (size, digest) in MODEL_FILES.items():
        target = destination / name
        if target.is_file() and target.stat().st_size == size and sha256(target) == digest:
            continue
        fetch(source + name, target, size, digest)
    (destination / "provenance.json").write_text(json.dumps({"source": source, "files": MODEL_FILES}, indent=2))
    emit({"event": "downloaded"})


def load_model(model_path):
    """Loads full-precision or quantized weights; quantized layers are rebuilt before loading."""
    import mlx.core as mx
    import mlx.nn as nn
    from mlx.utils import tree_flatten, tree_unflatten
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.utils import from_config

    config = json.loads((model_path / "config.json").read_text())
    quantization = config.get("quantization")
    if not quantization:
        return from_pretrained(str(model_path))
    model = from_config(config)
    target = model.encoder if quantization.get("strategy") == "encoder_only" else model
    nn.quantize(target, group_size=quantization["group_size"], bits=quantization["bits"])
    model.load_weights(str(model_path / "model.safetensors"))
    # Cast floating parameters only: quantized weights are packed integers.
    parameters = [(key, value.astype(mx.bfloat16) if mx.issubdtype(value.dtype, mx.floating) else value)
                  for key, value in tree_flatten(model.parameters())]
    model.update(tree_unflatten(parameters))
    return model


def watch_parent(interval=2.0):
    """Exit if Orator dies: stdin EOF is not noticed during a long inference."""
    import threading

    def run():
        while True:
            time.sleep(interval)
            if os.getppid() == 1:
                os._exit(0)
    threading.Thread(target=run, name="parent-watch", daemon=True).start()


def serve(model_path, root):
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    watch_parent()
    # Fail closed if a Python dependency attempts a network connection at runtime.
    import socket
    def deny_network(*args, **kwargs):
        raise OSError("Network access is disabled in the local recognition worker")
    socket.socket.connect = deny_network
    socket.socket.connect_ex = deny_network
    socket.create_connection = deny_network
    # All third-party stdout is diagnostic, never part of the wire protocol.
    sys.stdout = sys.stderr
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    try:
        model_path = Path(model_path).expanduser().resolve(strict=True)
        if not (model_path / "model.safetensors").is_file():
            raise ValueError("Local model weights are missing")
        model = load_model(model_path)
        mx.eval(model.parameters())
        model.generate(get_logmel(mx.zeros(16000, dtype=mx.float32), model.preprocessor_config))
        mx.clear_cache()
        emit({"event": "ready", "sampleRate": SAMPLE_RATE})
    except Exception as error:
        emit({"event": "fatal", "code": type(error).__name__,
              "message": "Cannot load local model. Check installation and model path."})
        return 1
    while True:
        line = sys.stdin.buffer.readline(MAX_REQUEST + 1)
        if not line:
            return 0
        if len(line) > MAX_REQUEST:
            emit({"event": "fatal", "message": "Request exceeds protocol limit"})
            return 1
        request_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Request must be an object")
            request_id = request.get("id")
            if not isinstance(request_id, str) or not request_id or len(request_id) > 128:
                raise ValueError("Invalid request identity")
            if request.get("op") == "ping":
                emit({"event": "pong", "id": request_id})
                continue
            if request.get("op") != "transcribe":
                raise ValueError("Unknown request operation")
            started = time.monotonic()
            audio = load_pcm(request["path"], root)
            text = transcribe(model, audio, request_id)
            emit({"event": "result", "id": request_id, "text": text,
                  "seconds": len(audio) / SAMPLE_RATE,
                  "elapsed": time.monotonic() - started,
                  "peakMemory": mx.get_peak_memory()})
            del audio
            mx.clear_cache()
        except Exception:
            # Do not echo arbitrary request fields, recorded speech or file contents.
            emit({"event": "error", "id": request_id,
                  "message": "Transcription failed. Recording retained for retry."})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--recordings", type=Path)
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    if args.download:
        download(args.model)
        return 0
    if args.recordings is None:
        parser.error("--recordings is required for the private worker")
    return serve(args.model, args.recordings)


if __name__ == "__main__":
    raise SystemExit(main())
