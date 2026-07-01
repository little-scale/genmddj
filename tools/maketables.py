#!/usr/bin/env python3
"""Generate the SN76489 PSG note-period + wavetable-increment tables for genmddj.

96 notes, C0..B7 (note 0 = C0; A4 = note 57 = 440 Hz). Each period is the 10-bit
PSG period = round(clock / (32 * freq)), clamped to 1..1023 (notes below the PSG's
range clamp to 1023). Big-endian 16-bit words.

Layout (the engine picks the NTSC or PAL half at runtime from opt_vid / eff_pal):

    +0      96 periods  (NTSC)
    +192    96 wave increments (NTSC)
    +384    16 x 256 DRIVE soft-clip table  (region-independent; shared)
    +4480   96 periods  (PAL)     <- PAL_NOTES offset in src/main.asm
    +4672   96 wave increments (PAL)

    maketables.py build/notes.bin
"""
import struct
import sys
import math

A4 = 57                  # note index of A4 (440 Hz)
WAVE_LEN = 32            # wavetable steps; phase is 8.8 fixed-point -> 32*256 units/cycle

# Per-region constants. The SN76489 PSG runs at master/15; the YM2612 Timer-A DAC
# feed rate scales with the YM clock (master/7). NTSC master = 53.693175 MHz,
# PAL master = 53.203424 MHz (ratio 0.99088).
NTSC = dict(psg_clock=3579545, dac_rate=5327)   # 53693175/15 ; ym/(144*10) = 53693175/7/1440
PAL  = dict(psg_clock=3546895, dac_rate=5278)   # 53203424/15 ; 53203424/7/1440


def periods(psg_clock):
    b = bytearray()
    for n in range(96):
        freq = 440.0 * 2.0 ** ((n - A4) / 12.0)
        period = max(1, min(1023, round(psg_clock / (32.0 * freq))))
        b += struct.pack(">H", period)
    return b


def wave_incs(dac_rate):
    # inc = freq * (WAVE_LEN*256) / dac_rate, so the 32-step wave loops at the note
    # frequency through the Z80 phase accumulator.
    b = bytearray()
    for n in range(96):
        freq = 440.0 * 2.0 ** ((n - A4) / 12.0)
        inc = max(1, min(65535, round(freq * WAVE_LEN * 256 / dac_rate)))
        b += struct.pack(">H", inc)
    return b


out = bytearray()
out += periods(NTSC["psg_clock"])            # +0    NTSC periods
out += wave_incs(NTSC["dac_rate"])           # +192  NTSC wave increments

# WAVE DRIVE soft-clip (appended at +384): 16 drive levels x 256 samples. Each entry maps
# an 8-bit sample through a normalised tanh (peak preserved): DRIVE 0 ~= clean, F ~= square.
for drv in range(16):
    if drv == 0:                                  # DRIVE 0 = clean pass-through (identity)
        out += bytes(range(256))
        continue
    gain = 1.0 + drv * 0.45
    tg = math.tanh(gain)
    for s in range(256):
        dev = s - 128
        outdev = 127.0 * math.tanh((dev / 128.0) * gain) / tg
        out += struct.pack("B", max(0, min(255, int(round(outdev)) + 128)))

assert len(out) == 4480, len(out)            # PAL_NOTES offset in src/main.asm
out += periods(PAL["psg_clock"])             # +4480  PAL periods
out += wave_incs(PAL["dac_rate"])            # +4672  PAL wave increments

open(sys.argv[1], "wb").write(out)
print(f"maketables: NTSC+PAL (96 periods + 96 wave incs each) + 16x256 DRIVE -> {sys.argv[1]} ({len(out)} B)")
