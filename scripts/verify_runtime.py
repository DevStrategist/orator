"""Exercise the actual offline worker using only synthetic, non-user speech."""
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
MODEL = Path.home() / "Library/Application Support/Orator/model"
PYTHON = ROOT / "runtime/.venv/bin/python"
PHRASE = "The quick brown fox jumps over the lazy dog. This transcription stays entirely on my Mac."


def main():
    with tempfile.TemporaryDirectory(prefix="orator-verification-") as temporary:
        temporary = Path(temporary)
        audio = temporary / "known.wav"
        subprocess.run(["say", "-o", str(audio), "--file-format=WAVE",
                        "--data-format=LEI16@16000", PHRASE], check=True)
        with wave.open(str(audio), "rb") as f:
            assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, 16000)
            pcm = f.readframes(f.getnframes())
        silence = temporary / "silence.pcm"
        silence.write_bytes(bytes(16000 * 2))
        long_audio = temporary / "long.pcm"
        long_audio.write_bytes((pcm + bytes(16000)) * 6)
        environment = os.environ.copy()
        for key in list(environment):
            if any(word in key.upper() for word in ["TOKEN", "SECRET", "API_KEY"]):
                environment.pop(key)
        environment.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_IMPLICIT_TOKEN="1")
        process = subprocess.Popen([str(PYTHON), "-u", str(ROOT / "runtime/worker.py"),
                                    "--model", str(MODEL), "--recordings", str(temporary)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, env=environment, bufsize=1)
        messages = queue.Queue()
        def reader():
            for line in process.stdout:
                messages.put(json.loads(line))
            messages.put({"event": "eof"})
        threading.Thread(target=reader, daemon=True).start()
        def receive(terminal, timeout=180):
            started = time.monotonic()
            while True:
                item = messages.get(timeout=max(1, timeout - (time.monotonic() - started)))
                if item.get("event") in ["fatal", "eof"]:
                    raise RuntimeError(f"Worker terminated: {item}")
                if item.get("event") in terminal:
                    return item
        def request(identifier, path=None, op="transcribe"):
            payload = {"id": identifier, "op": op}
            if path is not None:
                payload["path"] = str(path)
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return receive(["result", "error", "pong"])
        try:
            started = time.monotonic()
            receive(["ready"])
            print(f"Offline model ready in {time.monotonic()-started:.2f}s", flush=True)
            results = []
            for number in range(3):
                item = request(f"phrase-{number}", audio)
                assert item["event"] == "result", item
                words = set(re.findall(r"[a-z]+", item["text"].lower()))
                assert {"quick", "brown", "fox", "lazy", "dog", "mac"} <= words, item
                results.append(item)
                print(f"Phrase {number+1}: {item['elapsed']:.2f}s; MLX peak {item['peakMemory']/1e9:.2f} GB; {item['text']}", flush=True)
            item = request("silence", silence)
            assert item["event"] == "result" and item["text"] == "", item
            print("Silence: empty result, no hallucinated text", flush=True)
            item = request("malformed-operation", op="not-an-operation")
            assert item["event"] == "error", item
            assert request("still-alive", op="ping")["event"] == "pong"
            item = request("outside-root", MODEL / "config.json")
            assert item["event"] == "error", item
            item = request("long-overlap", long_audio)
            assert item["event"] == "result", item
            assert item["text"].lower().count("quick brown fox") == 6, item
            print(f"Long recording: {item['seconds']:.1f}s; {item['elapsed']:.2f}s inference; 6 phrases preserved; MLX peak {item['peakMemory']/1e9:.2f} GB", flush=True)
            print("Actual model verification passed: repeated warm requests, silence, invalid operation, outside-root refusal, liveness and overlap.", flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
