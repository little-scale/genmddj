#!/usr/bin/env python3
"""Bake the factory WAVE bank: 16 wavetables x 32 steps x 8-bit unsigned (128 = centre).

Emitted as build/wave_bank.bin (512 bytes), incbin'd after the "GMDJWAV0" locator in
main.asm. clear_song seeds the song's WAVE pool from it (so boot + every NEW start with
these). The browser wave ROM-patcher edits this bank in a built .bin.

Like makefont.py: if tools/wave_custom.bin (512 bytes) exists it is used verbatim
(a bank exported from the browser tool for a build-time bake); otherwise the default
set below is generated.
"""
import sys, os, math

STEPS, NWAVE = 32, 16
clamp = lambda v: max(0, min(255, int(round(v))))


def gen_default():
    w = []
    sin = lambda h, s: 128 + 127 * math.sin(2 * math.pi * h * s / STEPS)
    w.append([clamp(sin(1, s)) for s in range(STEPS)])                                  # 0  sine
    w.append([clamp((s / (STEPS / 2) if s < STEPS / 2 else 2 - s / (STEPS / 2)) * 255)  # 1  triangle
              for s in range(STEPS)])
    w.append([clamp(s / (STEPS - 1) * 255) for s in range(STEPS)])                      # 2  saw
    w.append([clamp(255 - s / (STEPS - 1) * 255) for s in range(STEPS)])                # 3  reverse saw
    w.append([255 if s < STEPS // 2 else 0 for s in range(STEPS)])                      # 4  square 50%
    w.append([255 if s < STEPS // 4 else 0 for s in range(STEPS)])                      # 5  pulse 25%
    w.append([255 if s < STEPS // 8 else 0 for s in range(STEPS)])                      # 6  pulse 12.5%
    w.append([clamp(abs(math.sin(math.pi * s / STEPS)) * 255) for s in range(STEPS)])   # 7  half sine
    w.append([clamp(sin(2, s)) for s in range(STEPS)])                                  # 8  organ (2nd harmonic)
    w.append([clamp(sin(3, s)) for s in range(STEPS)])                                  # 9  3rd harmonic
    w.append([clamp(sin(5, s)) for s in range(STEPS)])                                  # 10 5th harmonic
    w.append([clamp(128 + 64 * math.sin(2 * math.pi * s / STEPS)                        # 11 sine + 2nd
              + 63 * math.sin(2 * math.pi * 2 * s / STEPS)) for s in range(STEPS)])
    w.append([clamp((s // (STEPS // 4)) / 3 * 255) for s in range(STEPS)])              # 12 4-step stairs
    trap = []                                                                            # 13 trapezoid
    for s in range(STEPS):
        t = s / STEPS
        trap.append(clamp(min(1.0, max(0.0, (t * 4 if t < 0.25 else (1 if t < 0.5 else (1 - (t - 0.5) * 4 if t < 0.75 else 0))))) * 255))
    w.append(trap)
    rng = 0x1234                                                                         # 14 noise (fixed seed -> reproducible build)
    nz = []
    for _ in range(STEPS):
        rng = (rng * 1103515245 + 12345) & 0xFFFFFFFF
        nz.append((rng >> 16) & 0xFF)
    w.append(nz)
    w.append([128] * STEPS)                                                              # 15 flat centre
    return w


custom = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wave_custom.bin")
if os.path.exists(custom) and os.path.getsize(custom) == NWAVE * STEPS:
    data = bytearray(open(custom, "rb").read())
    note = f"custom bank {os.path.basename(custom)}"
else:
    if os.path.exists(custom):
        sys.stderr.write(f"makewaves: {custom} is not {NWAVE*STEPS} bytes -- ignoring, using default bank\n")
    data = bytearray()
    for wv in gen_default():
        data += bytes(wv)
    note = f"{NWAVE} default waves x {STEPS} steps"

assert len(data) == NWAVE * STEPS, len(data)
open(sys.argv[1], "wb").write(data)
print(f"makewaves: {len(data)} bytes ({note})")
