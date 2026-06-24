#!/usr/bin/env python3
"""Procedural SFX generator for Soomgo Arcade.

Every sound here is synthesised from scratch with NumPy (sine/triangle/noise
envelopes) — there are NO samples, recordings, or third-party assets involved, so
the output is 100% original and free to ship commercially. Re-run to regenerate the
bundled WAVs:

    python3 assets/audio/generate_sfx.py

Provenance is recorded in docs/audio.md. Keep this script in the repo so the asset
chain stays reproducible and auditable.
"""

import math
import os
import struct
import wave

import numpy as np

SR = 44100
OUT_DIR = os.path.dirname(os.path.abspath(__file__))


def _env(n, attack=0.005, release=0.08):
    """Linear attack / exponential-ish release amplitude envelope."""
    env = np.ones(n)
    a = max(1, int(attack * SR))
    r = max(1, int(release * SR))
    env[:a] = np.linspace(0.0, 1.0, a)
    if r < n:
        env[n - r:] = np.linspace(1.0, 0.0, r) ** 1.6
    return env


def _t(dur):
    return np.linspace(0.0, dur, int(dur * SR), endpoint=False)


def _sine(freq, t):
    return np.sin(2.0 * math.pi * freq * t)


def _tri(freq, t):
    return 2.0 / math.pi * np.arcsin(np.sin(2.0 * math.pi * freq * t))


def _norm(x, peak=0.9):
    m = np.max(np.abs(x)) or 1.0
    return x / m * peak


def balloon_place():
    # Short watery "plip" — quick downward pitch blip.
    t = _t(0.16)
    freq = np.linspace(680, 320, t.size)
    phase = 2.0 * math.pi * np.cumsum(freq) / SR
    body = np.sin(phase)
    return _norm(body * _env(t.size, 0.003, 0.12)) * 0.8


def explosion():
    # Low thump + filtered noise burst for the detonation / chain.
    t = _t(0.5)
    noise = np.random.default_rng(1).standard_normal(t.size)
    # one-pole low-pass to take the harsh edge off the noise
    lp = np.zeros_like(noise)
    a = 0.35
    for i in range(1, noise.size):
        lp[i] = a * noise[i] + (1 - a) * lp[i - 1]
    thump_f = np.linspace(140, 50, t.size)
    thump = np.sin(2.0 * math.pi * np.cumsum(thump_f) / SR)
    mix = 0.7 * lp + 0.6 * thump
    return _norm(mix * _env(t.size, 0.002, 0.42)) * 0.95


def trapped():
    # Descending bubbly "glug" — player caught in a bubble.
    t = _t(0.32)
    freq = np.linspace(520, 180, t.size)
    body = _sine(freq, t) + 0.3 * np.sin(2.0 * math.pi * freq * 2 * t)
    wobble = 1.0 + 0.12 * np.sin(2.0 * math.pi * 18 * t)
    return _norm(body * wobble * _env(t.size, 0.004, 0.2)) * 0.75


def rescue():
    # Bright rising two-note chime — a teammate pops you free.
    out = np.zeros(int(0.34 * SR))
    for i, f in enumerate((523.25, 783.99)):  # C5 -> G5
        seg = _t(0.2)
        start = int(i * 0.12 * SR)
        tone = _sine(f, seg) * _env(seg.size, 0.004, 0.16)
        out[start:start + seg.size] += tone[:out.size - start]
    return _norm(out) * 0.8


def eliminated():
    # Descending three-step "down" motif — knocked out / drowned.
    out = np.zeros(int(0.46 * SR))
    for i, f in enumerate((440.0, 349.23, 261.63)):  # A4 -> F4 -> C4
        seg = _t(0.18)
        start = int(i * 0.12 * SR)
        tone = _tri(f, seg) * _env(seg.size, 0.004, 0.14)
        out[start:start + seg.size] += tone[:out.size - start]
    return _norm(out) * 0.8


def countdown_tick():
    # Short neutral blip for "3 · 2 · 1".
    t = _t(0.1)
    body = _sine(660, t)
    return _norm(body * _env(t.size, 0.002, 0.08)) * 0.7


def countdown_go():
    # Higher, slightly longer "go!" cue when the round starts.
    t = _t(0.22)
    body = _sine(880, t) + 0.3 * _sine(1320, t)
    return _norm(body * _env(t.size, 0.002, 0.18)) * 0.85


def round_win():
    # Short ascending arpeggio fanfare for a round result.
    out = np.zeros(int(0.5 * SR))
    for i, f in enumerate((523.25, 659.25, 783.99)):  # C5 E5 G5
        seg = _t(0.22)
        start = int(i * 0.1 * SR)
        tone = (_sine(f, seg) + 0.3 * _tri(f * 2, seg)) * _env(seg.size, 0.004, 0.16)
        out[start:start + seg.size] += tone[:out.size - start]
    return _norm(out) * 0.85


def series_win():
    # Longer four-note triumphant fanfare for clinching the series.
    out = np.zeros(int(0.8 * SR))
    for i, f in enumerate((523.25, 659.25, 783.99, 1046.50)):  # C5 E5 G5 C6
        seg = _t(0.34)
        start = int(i * 0.12 * SR)
        tone = (_sine(f, seg) + 0.35 * _tri(f * 2, seg)) * _env(seg.size, 0.004, 0.26)
        out[start:start + seg.size] += tone[:out.size - start]
    return _norm(out) * 0.9


def skill():
    # Unique-skill cast: a quick upward "whoosh" plus a bright shimmer, distinct from the
    # balloon/explosion cues so a fired skill is unmistakable.
    t = _t(0.3)
    sweep = np.linspace(330, 990, t.size)
    body = _sine(sweep, t) + 0.4 * _tri(sweep * 1.5, t)
    shimmer = 0.3 * np.sin(2.0 * math.pi * 1760 * t) * np.linspace(0.0, 1.0, t.size)
    return _norm((body + shimmer) * _env(t.size, 0.003, 0.2)) * 0.82


SOUNDS = {
    "balloon_place": balloon_place,
    "explosion": explosion,
    "trapped": trapped,
    "rescue": rescue,
    "eliminated": eliminated,
    "skill": skill,
    "countdown_tick": countdown_tick,
    "countdown_go": countdown_go,
    "round_win": round_win,
    "series_win": series_win,
}


def write_wav(path, samples):
    pcm = np.clip(samples, -1.0, 1.0)
    pcm16 = (pcm * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm16.tobytes())


def main():
    for name, fn in SOUNDS.items():
        out = os.path.join(OUT_DIR, "%s.wav" % name)
        write_wav(out, fn())
        print("wrote", out)


if __name__ == "__main__":
    main()
