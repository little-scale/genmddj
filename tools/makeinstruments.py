#!/usr/bin/env python3
# makeinstruments.py -- build the 32-slot FM factory bank from instrument-patches/*.gmi.
# Instruments are taken in filename order; each name is set from the filename (the "NN "
# index prefix stripped, uppercased, kept to 8 chars). Emits a 2048-byte binary that
# main.asm incbin's behind the GMINSTR0 locator. Run by the Makefile at build time.
#
#   usage: makeinstruments.py <src-dir> <out.bin> [--b64]
#   --b64: also print base64 of the bank + the JS name array (for the patcher's DEFAULT_BANK)
import sys, os, re, glob, base64

NINSTR, REC = 32, 64
GMI_MAGIC = b"GMDJINS1"

# a plain single-carrier FM sine, used to pad unused slots
def init_record(name="INIT"):
    r = bytearray(REC)
    r[0:8] = bytes([0, 7, 0, 3, 0, 0, 15, 15])          # type FM, algo 7, fb 0, L+R, hld/vol
    r[8:18]  = bytes([1, 0, 0, 0, 31, 0, 0, 0, 15, 0])  # op0 carrier: MUL1 TL0 AR31 RR15
    for k in range(1, 4):                                # op1-3 silent (TL 127)
        r[8 + k*10 : 8 + k*10 + 10] = bytes([1, 0, 127, 0, 0, 0, 0, 0, 15, 0])
    r[48] = 0xFF                                          # i_tbl = none
    set_name(r, name)
    return r

def set_name(rec, name):
    name = re.sub(r'[^A-Za-z0-9.]', '', name).upper()[:8]   # alnum/dot, upper, max 8 (trim what won't fit)
    rec[54:62] = (name + "        ")[:8].encode("ascii")    # space-pad to 8

def derive_name(path):
    base = os.path.splitext(os.path.basename(path))[0]      # drop .gmi
    return re.sub(r'^\s*\d+\s+', '', base)                  # drop the leading "NN " index

def main():
    src, out = sys.argv[1], sys.argv[2]
    want_b64 = '--b64' in sys.argv
    files = sorted(f for f in glob.glob(os.path.join(src, "*.gmi"))
                   if not os.path.basename(f).startswith('.'))
    names, bank = [], bytearray()
    for path in files[:NINSTR]:
        data = open(path, "rb").read()
        if len(data) != 8 + REC or data[:8] != GMI_MAGIC:
            sys.stderr.write(f"makeinstruments: skip {path} (not a 72-byte .gmi)\n"); continue
        rec = bytearray(data[8:8 + REC])
        set_name(rec, derive_name(path))
        bank += rec
        names.append(rec[54:62].decode('ascii').rstrip())
    n = len(bank) // REC
    while len(bank) < NINSTR * REC:                          # pad unused slots with INIT
        bank += init_record(); names.append("INIT")
    bank = bank[:NINSTR * REC]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    open(out, "wb").write(bank)
    sys.stderr.write(f"makeinstruments: {n} patches -> {out} ({len(bank)} B): {', '.join(names[:n])}\n")
    if want_b64:
        print("BANK_B64=" + base64.b64encode(bank).decode())
        print("DEFNAMES=" + repr(names[:20]))

if __name__ == "__main__":
    main()
