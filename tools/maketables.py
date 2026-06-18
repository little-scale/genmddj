#!/usr/bin/env python3
"""Generate the SN76489 PSG note-period table (NTSC) for genmddj.

96 notes, C0..B7 (note 0 = C0; A4 = note 57 = 440 Hz). Each entry is the
10-bit PSG period = round(clock / (32 * freq)), clamped to 1..1023. Notes
below the PSG's range clamp to 1023 (lowest pitch). Big-endian 16-bit words.

    maketables.py build/notes.bin
"""
import struct
import sys

CLOCK = 3579545          # NTSC PSG clock (PAL table is a later addition)
A4 = 57                  # note index of A4
out = bytearray()
for n in range(96):
    freq = 440.0 * 2.0 ** ((n - A4) / 12.0)
    period = round(CLOCK / (32.0 * freq))
    period = max(1, min(1023, period))
    out += struct.pack(">H", period)

open(sys.argv[1], "wb").write(out)
print(f"maketables: {len(out)//2} note periods (C0-B7, NTSC) -> {sys.argv[1]}")
