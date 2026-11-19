#!/usr/bin/env python3
"""Generates SleepFlow's original binary resources: the app icon and the alarm sounds.

Everything is synthesised from scratch (no samples, no third-party material), so the app ships
only content it owns. Run from the repository root:  python3 tools/generate_resources.py
Requires numpy and Pillow.
"""
import json
import math
import os
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "App", "Resources")
ASSETS = os.path.join(RES, "Assets.xcassets")
SOUNDS = os.path.join(RES, "Sounds")
RATE = 22_050


# ----------------------------------------------------------------------------- asset catalog

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def color_set(name, light, dark):
    def comp(hex_value):
        return {
            "color": {
                "color-space": "srgb",
                "components": {
                    "red": f"0x{(hex_value >> 16) & 0xFF:02X}",
                    "green": f"0x{(hex_value >> 8) & 0xFF:02X}",
                    "blue": f"0x{hex_value & 0xFF:02X}",
                    "alpha": "1.000",
                },
            },
            "idiom": "universal",
        }

    light_entry = comp(light)
    dark_entry = comp(dark)
    dark_entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
    write_json(os.path.join(ASSETS, f"{name}.colorset", "Contents.json"), {
        "colors": [light_entry, dark_entry],
        "info": {"author": "xcode", "version": 1},
    })


def lerp(a, b, t):
    return a + (b - a) * t


def hex_rgb(value):
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


def make_icon(path, size=1024):
    """Midnight-blue square, a warm crescent moon and three flowing 'sleep cycle' waves."""
    s = size * 2  # supersample for clean edges
    img = Image.new("RGB", (s, s))
    top, bottom = hex_rgb(0x111B44), hex_rgb(0x050816)
    px = img.load()
    for y in range(s):
        t = y / (s - 1)
        row = tuple(int(lerp(top[i], bottom[i], t)) for i in range(3))
        for x in range(s):
            px[x, y] = row

    cx, cy, r = int(s * 0.60), int(s * 0.38), int(s * 0.26)

    # Crescent: a disc minus an offset disc.
    moon = Image.new("L", (s, s), 0)
    mdraw = ImageDraw.Draw(moon)
    mdraw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    cut = Image.new("L", (s, s), 0)
    cdraw = ImageDraw.Draw(cut)
    ox, oy = int(r * 0.42), int(-r * 0.30)
    cdraw.ellipse((cx - r + ox, cy - r + oy, cx + r + ox, cy + r + oy), fill=255)
    crescent = Image.fromarray(np.clip(np.array(moon, dtype=np.int16) - np.array(cut, dtype=np.int16), 0, 255).astype(np.uint8))
    moon_fill = Image.new("RGB", (s, s))
    mpx = moon_fill.load()
    warm_a, warm_b = hex_rgb(0xFFB25B), hex_rgb(0xFF7A2E)
    for y in range(s):
        t = min(max((y - (cy - r)) / (2 * r), 0), 1)
        row = tuple(int(lerp(warm_a[i], warm_b[i], t)) for i in range(3))
        for x in range(s):
            mpx[x, y] = row
    img = Image.composite(moon_fill, img, crescent)

    # Three waves: one sleep cycle each, fading out. Drawn by stamping discs along the curve,
    # which gives clean, round strokes at any thickness.
    draw = ImageDraw.Draw(img)
    base_y = s * 0.70
    width = s * 0.026
    for index, (alpha, amp) in enumerate([(1.0, 0.055), (0.55, 0.045), (0.28, 0.035)]):
        color = tuple(int(lerp(hex_rgb(0x0B1030)[i], hex_rgb(0xFFB25B)[i], alpha)) for i in range(3))
        y0 = base_y + index * s * 0.085
        steps = 1600
        for k in range(steps + 1):
            x = s * 0.12 + (s * 0.76) * k / steps
            y = y0 - math.sin(k / steps * math.pi * 2.0 + index * 0.7) * s * amp
            rr = width / 2
            draw.ellipse((x - rr, y - rr, x + rr, y + rr), fill=color)

    # A few stars.
    for (sx, sy, sr) in [(0.24, 0.22, 0.012), (0.13, 0.33, 0.007), (0.18, 0.47, 0.006), (0.82, 0.16, 0.008)]:
        draw.ellipse((s * (sx - sr), s * (sy - sr), s * (sx + sr), s * (sy + sr)), fill=(236, 240, 255))

    img = img.resize((size, size), Image.LANCZOS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)


def make_assets():
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    make_icon(os.path.join(ASSETS, "AppIcon.appiconset", "AppIcon-1024.png"))
    write_json(os.path.join(ASSETS, "AppIcon.appiconset", "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    })
    color_set("AccentColor", 0xE8701F, 0xFF8A3D)
    color_set("LaunchBackground", 0x060A18, 0x060A18)


# ----------------------------------------------------------------------------- alarm sounds

def envelope(n, attack, release):
    env = np.ones(n)
    a = max(1, int(attack * RATE))
    r = max(1, int(release * RATE))
    env[:a] = np.linspace(0, 1, a) ** 2
    env[-r:] *= np.linspace(1, 0, r) ** 2
    return env


def tone(freq, duration, partials=((1, 1.0),), attack=0.01, release=0.2, decay=None):
    n = int(duration * RATE)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for ratio, amp in partials:
        out += amp * np.sin(2 * np.pi * freq * ratio * t)
    out *= envelope(n, attack, release)
    if decay:
        out *= np.exp(-t / decay)
    return out


def place(buffer, signal, start):
    i = int(start * RATE)
    end = min(len(buffer), i + len(signal))
    buffer[i:end] += signal[: end - i]


def crescendo(n, start=0.35):
    return np.linspace(start, 1.0, n) ** 1.3


def finish(signal):
    peak = np.max(np.abs(signal)) or 1
    signal = signal / peak * 0.85
    fade = int(0.05 * RATE)
    signal[:fade] *= np.linspace(0, 1, fade)
    signal[-fade:] *= np.linspace(1, 0, fade)
    return signal


def write_wav(name, signal):
    os.makedirs(SOUNDS, exist_ok=True)
    data = (np.clip(signal, -1, 1) * 32767).astype("<i2")
    with wave.open(os.path.join(SOUNDS, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data.tobytes())


def note(semitones_from_a4):
    return 440.0 * 2 ** (semitones_from_a4 / 12)


def sunrise(duration=28.0):
    """Warm pentatonic arpeggio that slowly speeds up and swells."""
    buf = np.zeros(int(duration * RATE))
    scale = [-9, -7, -5, -2, 0, 3, 5, 7, 10, 12]  # C major pentatonic around A4
    t, step, i = 0.0, 0.9, 0
    while t < duration - 1.5:
        f = note(scale[(i * 3) % len(scale)] - 12 + (12 if i % 7 == 6 else 0))
        place(buf, tone(f, 1.6, partials=((1, 1.0), (2, 0.25), (3, 0.08)), attack=0.03, release=1.0, decay=0.9), t)
        t += step
        step = max(0.32, step * 0.965)
        i += 1
    pad_n = len(buf)
    tt = np.arange(pad_n) / RATE
    pad = sum(np.sin(2 * np.pi * note(s - 24) * tt) for s in (-9, -5, -2)) * 0.12
    buf += pad * np.linspace(0.2, 1, pad_n)
    return finish(buf * crescendo(len(buf)))


def morning_bells(duration=26.0):
    """Bell tones with inharmonic partials, a short phrase repeated."""
    buf = np.zeros(int(duration * RATE))
    phrase = [7, 3, 5, -2]
    bell = ((1, 1.0), (2.76, 0.45), (5.40, 0.25), (8.93, 0.12))
    t = 0.0
    while t < duration - 3:
        for k, s in enumerate(phrase):
            place(buf, tone(note(s), 2.8, partials=bell, attack=0.002, release=1.2, decay=0.8), t + k * 0.55)
        t += 3.2
    return finish(buf * crescendo(len(buf), 0.3))


def soft_pulse(duration=24.0):
    """Gentle triple pulses of a rounded sine."""
    buf = np.zeros(int(duration * RATE))
    t = 0.0
    while t < duration - 1:
        for k in range(3):
            place(buf, tone(660, 0.16, partials=((1, 1.0), (2, 0.1)), attack=0.02, release=0.08), t + k * 0.24)
        t += 1.6
    return finish(buf * crescendo(len(buf), 0.25))


def birdsong(duration=26.0, seed=7):
    """Synthetic chirps: short frequency sweeps in random little phrases (no recordings)."""
    rng = np.random.default_rng(seed)
    buf = np.zeros(int(duration * RATE))
    t = 0.3
    while t < duration - 1:
        count = rng.integers(2, 6)
        base = rng.uniform(2_600, 4_200)
        for k in range(count):
            length = rng.uniform(0.06, 0.14)
            n = int(length * RATE)
            tt = np.arange(n) / RATE
            sweep = base * (1 + rng.uniform(-0.25, 0.35) * np.sin(np.pi * tt / length))
            phase = 2 * np.pi * np.cumsum(sweep) / RATE
            chirp = np.sin(phase) * np.sin(np.pi * tt / length) ** 2
            place(buf, chirp * rng.uniform(0.5, 1.0), t)
            t += length + rng.uniform(0.03, 0.09)
        t += rng.uniform(0.6, 1.8)
    tt = np.arange(len(buf)) / RATE
    air = (rng.standard_normal(len(buf)) * 0.004) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.1 * tt))
    return finish((buf + air) * crescendo(len(buf), 0.35))


def classic(duration=22.0):
    """Classic digital alarm: beep-beep-beep-beep, pause."""
    buf = np.zeros(int(duration * RATE))
    t = 0.0
    while t < duration - 1:
        for k in range(4):
            place(buf, tone(1_000, 0.1, partials=((1, 1.0), (3, 0.3), (5, 0.12)), attack=0.004, release=0.02), t + k * 0.16)
        t += 1.0
    return finish(buf * crescendo(len(buf), 0.5))


def make_sounds():
    write_wav("sunrise.wav", sunrise())
    write_wav("morning-bells.wav", morning_bells())
    write_wav("soft-pulse.wav", soft_pulse())
    write_wav("birdsong.wav", birdsong())
    write_wav("classic.wav", classic())


if __name__ == "__main__":
    make_assets()
    make_sounds()
    print("Resources written to", RES)
