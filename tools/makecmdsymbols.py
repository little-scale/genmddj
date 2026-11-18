#!/usr/bin/env python3
"""Generate the seven dedicated extended-command glyphs as Mega Drive tiles.

The command namespace reserves, in order:
    alpha, beta, gamma, delta, epsilon, zeta, theta

Each symbol is emitted twice: seven normal tiles followed by seven inverse tiles.
Keeping these outside the patchable ASCII font means custom fonts cannot accidentally
turn an extended command back into punctuation.
"""
import sys


SYMBOLS = (
    ("ALPHA", (
        "......",
        ".###.#",
        "#...##",
        "#....#",
        "#...##",
        ".###.#",
        "......",
    )),
    ("BETA", (
        "###..",
        "#..#.",
        "###..",
        "#..#.",
        "###..",
        "#....",
        "#....",
    )),
    ("GAMMA", (
        ".....",
        "#...#",
        ".#.#.",
        "..#..",
        "..#..",
        ".#...",
        "#....",
    )),
    ("DELTA", (
        ".###.",
        "..#..",
        ".###.",
        "#...#",
        "#...#",
        ".###.",
        ".....",
    )),
    ("EPSILON", (
        ".....",
        ".####",
        "#....",
        ".###.",
        "#....",
        ".####",
        ".....",
    )),
    ("ZETA", (
        "#####",
        "...#.",
        "..#..",
        ".#...",
        "#....",
        ".###.",
        "....#",
    )),
    ("THETA", (
        ".###.",
        "#...#",
        "#####",
        "#...#",
        ".###.",
        ".....",
        ".....",
    )),
)


def glyph_rows(rows):
    """Return eight row masks; bit 0 is the leftmost pixel."""
    out = []
    for row in rows:
        bits = 0
        for col, char in enumerate(row[:8]):
            if char == '#':
                bits |= 1 << col
        out.append(bits)
    out.append(0)
    return out


def emit(fg, bg):
    out = bytearray()
    for _, rows in SYMBOLS:
        for row in glyph_rows(rows):
            for pair in range(0, 8, 2):
                hi = fg if (row >> pair) & 1 else bg
                lo = fg if (row >> (pair + 1)) & 1 else bg
                out.append((hi << 4) | lo)
    return out


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: makecmdsymbols.py build/cmd_symbols.bin")
    data = emit(1, 0) + emit(2, 1)
    with open(sys.argv[1], "wb") as output:
        output.write(data)
    print("makecmdsymbols: %d symbols, %d tiles -> %s" %
          (len(SYMBOLS), len(data) // 32, sys.argv[1]))


if __name__ == '__main__':
    main()
