#!/usr/bin/env python3
"""Convert a logo PNG into Mega Drive 4bpp tiles + a deduplicated tilemap.

  makesplash.py <in.png> <tiles.bin> <map.bin> <out.i> [tiles_wide]

Foreground (dark, opaque) pixels become colour index 1 (so the logo renders in
the palette's c1, like the font); everything else is index 0 (transparent).
Emits an asm include with SPLASH_W / SPLASH_H / SPLASH_NTILES and incbins.
"""
import sys
from PIL import Image


def main():
    src, out_tiles, out_map, out_inc = sys.argv[1:5]
    tw = int(sys.argv[5]) if len(sys.argv) > 5 else 32

    im = Image.open(src).convert("RGBA")
    W = tw * 8
    H = round(im.height * W / im.width)
    im = im.resize((W, H), Image.LANCZOS)
    th = (H + 7) // 8
    HH = th * 8
    canvas = Image.new("RGBA", (W, HH), (0, 0, 0, 0))
    canvas.paste(im, (0, (HH - H) // 2))
    px = canvas.load()

    def is_fg(x, y):
        r, g, b, a = px[x, y]
        return a >= 128 and (r + g + b) < 384      # opaque and dark

    uniq, index, tilemap = [], {}, []
    for ty in range(th):
        for tx in range(tw):
            tile = bytearray(32)                    # 8 rows x 4 bytes (2px/byte)
            for row in range(8):
                for col in range(8):
                    if is_fg(tx * 8 + col, ty * 8 + row):
                        bi = row * 4 + (col >> 1)
                        tile[bi] |= 0x01 if (col & 1) else 0x10
            key = bytes(tile)
            if key not in index:
                index[key] = len(uniq)
                uniq.append(key)
            tilemap.append(index[key])

    with open(out_tiles, "wb") as f:
        for t in uniq:
            f.write(t)
    with open(out_map, "wb") as f:
        f.write(bytes(tilemap))
    # equates only (included early; the tile/map data is incbin'd late in main.asm)
    with open(out_inc, "w") as f:
        f.write(f"SPLASH_W equ {tw}\n")
        f.write(f"SPLASH_H equ {th}\n")
        f.write(f"SPLASH_NTILES equ {len(uniq)}\n")

    assert len(uniq) <= 256, "tilemap byte overflow: too many unique tiles"
    print(f"splash: {tw}x{th} tiles, {len(uniq)} unique, map {len(tilemap)} cells")


if __name__ == "__main__":
    main()
