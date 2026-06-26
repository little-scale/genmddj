#!/usr/bin/env python3
"""rletest.py -- measure RLE compression of genmddj song data blocks.

This is the reference codec we'll port to the 68k (cart save/load) and to JS (the
savetool). It exists to answer one question on REAL songs before we commit to any
format change: does compressing the flat 20,832-byte data block buy enough to be
worth a directory + allocator + the OPTIONS rework?

RLE stream format (PackBits-style, byte-oriented, *canonical* decode -- two
different encoders may emit different streams that both decode identically, so the
cart and the savetool only have to agree on this decoder, not on encoder output):

    control byte c:
      bit7 = 0  -> literal run : copy the next (c & 0x7F)+1 bytes verbatim   (1..128)
      bit7 = 1  -> repeat run  : next 1 byte, output (c & 0x7F)+2 times       (2..129)

Worst case (all literals) expands by 1 control byte per 128 -> ~0.78%. On the cart
we pair this with a STORE-RAW fallback (a flag in the slot header), so the stored
size is always min(rle, raw): compression can only help, never hurt.

Usage:
    rletest.py                       # self-test on synthetic blocks (no .gmdj needed)
    rletest.py a.gmdj b.gmdj ...     # measure real songs, with totals
    rletest.py --pools song.gmdj     # add a per-pool breakdown
"""

import sys

GMDJ_MAGIC = b"GMDJSONG"
DATA_OFF   = 32            # .gmdj header bytes before the data block
DATA_LEN   = 23904         # $5D60 -- the flat data block (phrases 192, chains 128)

# data-block pool map (name, offset, length) -- from SAVEFORMAT.md / the SAVE_DATA
# comment in src/main.asm. Lets us see which pools carry the redundancy.
POOLS = [
    ("globals",     0,   256),
    ("song",      256,  2400),
    ("phrases",  2656, 12288),
    ("chains",  14944,  4096),
    ("instr",   19040,  2048),
    ("tables",  21088,  2048),
    ("grooves", 23136,   256),
    ("waves",   23392,   512),
]

# cart sizes + a rough reservation for config + the 32-slot instrument bank +
# the song directory, used only for the "songs per cart" ballpark.
SRAM = {"32K": 32768, "64K": 65536}
RESERVE = 3072
DIR_PER_SONG = 16


# RLE granularity. UNIT=4 matches the phrase/chain row (note/instr/cmd/param), so an empty
# row (FF FF 00 00) is ONE repeated unit. Byte-RLE (UNIT=1) leaves phrases/chains at 100%
# because that pattern alternates every 2 bytes; 4-byte units crush them (~67% -> ~9%).
# The data block and every pool length are multiples of 4, so units divide cleanly.
UNIT = 4


def rle_compress(data: bytes) -> bytes:
    out = bytearray()
    n = len(data) // UNIT
    U = [data[k*UNIT:(k+1)*UNIT] for k in range(n)]
    i = 0
    while i < n:
        run = 1
        while i + run < n and U[i + run] == U[i] and run < 129:
            run += 1
        if run >= 2:                                   # repeat run: 1 ctrl + 1 unit
            out.append(0x80 | (run - 2)); out += U[i]; i += run
            continue
        j = i                                          # literal run up to the next 2+ run
        while j < n and (j - i) < 128 and not (j + 1 < n and U[j + 1] == U[j]):
            j += 1
        if j == i:
            j = i + 1
        out.append((j - i) - 1)
        for k in range(i, j):
            out += U[k]
        i = j
    out += data[n*UNIT:]                                # tail bytes (none for a 4-multiple)
    return bytes(out)


def rle_decompress(data: bytes) -> bytes:
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        c = data[i]; i += 1
        if c & 0x80:
            out += data[i:i + UNIT] * ((c & 0x7F) + 2); i += UNIT
        else:
            cnt = (c & 0x7F) + 1
            out += data[i:i + cnt*UNIT]; i += cnt*UNIT
    return bytes(out)


def measure(block: bytes) -> dict:
    rle = rle_compress(block)
    assert rle_decompress(rle) == block, "round-trip mismatch -- codec bug!"
    raw = len(block)
    store_raw = len(rle) >= raw
    on_cart = min(len(rle), raw)
    return {"raw": raw, "rle": len(rle), "on_cart": on_cart,
            "store_raw": store_raw, "ratio": on_cart / raw}


def songs_per_cart(on_cart: int) -> dict:
    return {k: max(0, (sz - RESERVE) // (on_cart + DIR_PER_SONG))
            for k, sz in SRAM.items()}


def load_block(path: str):
    raw = open(path, "rb").read()
    if raw[:8] == GMDJ_MAGIC and len(raw) >= DATA_OFF + DATA_LEN:
        title = bytes(b for b in raw[11:19] if 32 <= b < 127).decode() or path
        return raw[DATA_OFF:DATA_OFF + DATA_LEN], title.strip()
    if len(raw) == DATA_LEN:
        return raw, path
    raise ValueError(f"{path}: not a .gmdj and not a {DATA_LEN}-byte data block "
                     f"({len(raw)} bytes)")


def report(label: str, block: bytes, pools: bool):
    m = measure(block)
    flag = "  [STORE RAW]" if m["store_raw"] else ""
    spc = songs_per_cart(m["on_cart"])
    print(f"{label:<16} raw {m['raw']:>6}  ->  {m['on_cart']:>6}  "
          f"({m['ratio']*100:5.1f}%)   ~{spc['32K']} / 32K, ~{spc['64K']} / 64K{flag}")
    if pools:
        for name, off, ln in POOLS:
            pm = measure(block[off:off + ln])
            print(f"    {name:<10} {ln:>6}  ->  {pm['on_cart']:>6}  ({pm['ratio']*100:5.1f}%)")
    return m


def self_test():
    print("self-test (synthetic blocks; round-trip verified):\n")
    blocks = {
        "all-FF (empty)":  bytes([0xFF]) * DATA_LEN,
        "all-00":          bytes(DATA_LEN),
        "sparse ~15% full": bytes(
            (i * 2654435761 & 0xFF) if (i * 40503 & 0xFFFF) < 9800 else 0xFF
            for i in range(DATA_LEN)),
        "random (worst)":  bytes((i * 2654435761 >> 13) & 0xFF for i in range(DATA_LEN)),
    }
    for name, b in blocks.items():
        report(name, b, False)
    print("\nempty/sparse compress hard; random hits the store-raw floor (=100%+epsilon).")
    print("feed real .gmdj files for the numbers that matter.")


def main(argv):
    args = [a for a in argv if a != "--pools"]
    pools = "--pools" in argv
    if not args:
        self_test(); return
    print(f"{'song':<16} {'raw':>10}      {'stored':>6}   ratio    songs/cart\n")
    totals = []
    for path in args:
        try:
            block, label = load_block(path)
        except (OSError, ValueError) as e:
            print(f"  skip: {e}"); continue
        totals.append(report(label, block, pools))
    if len(totals) > 1:
        raw = sum(t["raw"] for t in totals)
        cart = sum(t["on_cart"] for t in totals)
        avg = sum(t["ratio"] for t in totals) / len(totals)
        print(f"\n{len(totals)} songs: {raw} -> {cart} stored, avg {avg*100:.1f}% of raw")


if __name__ == "__main__":
    main(sys.argv[1:])
