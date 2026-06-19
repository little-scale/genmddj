#!/usr/bin/env python3
"""Patch the Mega Drive ROM header checksum.

The MD checksum (header offset $18E, big-endian word) is the sum of every 16-bit
word from $200 to the end of the ROM, mod $10000. Real hardware and strict
emulators verify it.

    fixheader.py in.bin out.bin
"""
import sys
import numpy as np

src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, "rb").read())

if len(data) % 2:                      # ROM must be an even number of bytes
    data.append(0xFF)
if len(data) < 0x200:
    sys.exit("ROM shorter than header (need >= $200 bytes)")

words = np.frombuffer(bytes(data[0x200:]), dtype=">u2")   # big-endian 16-bit words
s = int(words.sum(dtype=np.uint64)) & 0xFFFF

data[0x18E] = (s >> 8) & 0xFF
data[0x18F] = s & 0xFF

open(dst, "wb").write(data)
print(f"fixheader: checksum ${s:04X}, {len(data)} bytes ({len(data)//1024} KB)")
