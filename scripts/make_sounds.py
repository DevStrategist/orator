#!/usr/bin/env python3
"""Renders Orator's start and stop cues into Resources/Sounds.

Each cue is two soft mallet notes a fifth apart: rising when the microphone is live, falling when
recording stops. They are short and quiet so they confirm the moment without getting in the way.
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
PEAK = 10 ** (-19 / 20)  # -19 dBFS
G4, D5 = 392.00, 587.33


def note(t, frequency, start, decay, amplitude):
    t -= start
    if t < 0:
        return 0.0
    attack = 0.004
    envelope = (0.5 - 0.5 * math.cos(math.pi * t / attack)) if t < attack else 1.0
    envelope *= math.exp(-t / decay)
    phase = 2 * math.pi * frequency * t
    tone = math.sin(phase) + 0.12 * math.sin(2 * phase)
    # A brief inharmonic partial gives the attack a soft mallet character.
    tone += 0.08 * math.sin(3.98 * phase) * math.exp(-t / 0.008)
    return amplitude * envelope * tone


def render(notes, duration):
    count = int(RATE * duration)
    fade = int(RATE * 0.02)
    samples = [sum(note(i / RATE, *n) for n in notes) for i in range(count)]
    for i in range(fade):
        samples[count - fade + i] *= 1 - i / fade
    scale = PEAK / max(abs(s) for s in samples)
    return [s * scale for s in samples]


def write(path, samples):
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(struct.pack("<h", round(s * 32767)) for s in samples))


def main():
    folder = Path(__file__).resolve().parent.parent / "Resources/Sounds"
    folder.mkdir(parents=True, exist_ok=True)
    write(folder / "start.wav", render([(G4, 0, 0.028, 0.8), (D5, 0.05, 0.045, 1.0)], 0.2))
    write(folder / "stop.wav", render([(D5, 0, 0.028, 0.9), (G4, 0.05, 0.05, 0.85)], 0.2))


if __name__ == "__main__":
    main()
