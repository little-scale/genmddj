#!/usr/bin/env python3
"""Convert the public-domain font8x8_basic 8x8 font into Mega Drive tiles.

Emits TWO 96-tile sets for ASCII $20..$7F (MD 4bpp planar, 8 rows x 4 bytes):
  - normal  (tiles 0..95):  glyph -> colour 1, background -> colour 0 (transparent)
  - inverse (tiles 96..191): background -> colour 1 (solid), glyph -> colour 2
The inverse set gives a true inverse-video cursor block (colour 0 is transparent
on the MD planes, so a palette swap alone can't fill the cell background).

Load normal at VRAM tile $20, inverse at tile $80 -> inverse tile = ASCII + $60.

    makefont.py tools/font8x8_basic.h build/font.bin
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
rows = re.findall(r"\{([^{}]*)\}", text)
glyphs = []
for r in rows:
    nums = re.findall(r"0x[0-9A-Fa-f]+", r)
    if len(nums) == 8:
        glyphs.append([int(n, 16) for n in nums])


def emit(fg, bg):
    out = bytearray()
    for code in range(0x20, 0x80):
        g = glyphs[code] if code < len(glyphs) else [0] * 8
        for row in g:
            for bx in range(0, 8, 2):
                hi = fg if (row >> bx) & 1 else bg          # bit0 = leftmost pixel
                lo = fg if (row >> (bx + 1)) & 1 else bg
                out.append((hi << 4) | lo)
    return out


data = emit(1, 0) + emit(2, 1)          # normal, then inverse
open(dst, "wb").write(data)
print(f"makefont: {len(data)} bytes ({len(data)//32} tiles: 96 normal + 96 inverse)")
