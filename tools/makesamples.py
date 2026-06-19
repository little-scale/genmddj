#!/usr/bin/env python3
"""Build the genmddj sample pool (kit directory + 8-bit PCM) from samples/kit NN/*.wav.

Pool layout (big-endian, 68k-native), labelled `sample_pool` in ROM:
  directory : NKITS * NPADS members, 8 bytes each
    member  = { u32 offset (bytes from pool start), u32 length }   (length 0 = empty pad)
  pcm       : concatenated 8-bit *unsigned* samples (0x80 = silence) at ~DAC_RATE Hz

The 68k reads a member directly (ROM is on its bus) and hands the Z80 the absolute
ROM pointer + length in the SCB DAC command; the Z80 streams it to YM2612 reg $2A.

    makesamples.py samples/ build/samples.bin
"""
import sys, os, glob, wave, struct
import numpy as np

NKITS = 8
NPADS = 16
DAC_RATE = 17756                 # k=3 Timer-A cadence (DESIGN Q2)
DIR_SIZE = NKITS * NPADS * 8


def load_wav_8bit(path):
    w = wave.open(path, 'rb')
    n, rate, width, ch = w.getnframes(), w.getframerate(), w.getsampwidth(), w.getnchannels()
    raw = w.readframes(n)
    if width == 3:                                  # 24-bit little-endian signed
        a = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = a[:, 0] | (a[:, 1] << 8) | (a[:, 2] << 16)
        v = np.where(v & 0x800000, v - 0x1000000, v).astype(np.float64) / 0x800000
    elif width == 2:
        v = np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0
    elif width == 1:
        v = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128) / 128.0
    else:
        raise SystemExit('unsupported sample width %d in %s' % (width, path))
    if ch == 2:
        v = v.reshape(-1, 2).mean(1)
    m = max(1, int(round(len(v) / rate * DAC_RATE)))         # resample to DAC_RATE
    v = np.interp(np.linspace(0, len(v) - 1, m), np.arange(len(v)), v)
    loud = np.where(np.abs(v) > 0.02)[0]                      # trim trailing silence
    if len(loud):
        v = v[:loud[-1] + 1]
    b = np.clip(np.round(v * 127) + 128, 0, 255).astype(np.uint8)   # 8-bit unsigned, 0x80 = silence
    return bytes(b)


def main():
    samples_dir, out = sys.argv[1], sys.argv[2]
    members = [[None] * NPADS for _ in range(NKITS)]
    pcm = bytearray()
    for k in range(NKITS):
        kdir = os.path.join(samples_dir, 'kit %02d' % k)
        if not os.path.isdir(kdir):
            continue
        for i, wpath in enumerate(sorted(glob.glob(os.path.join(kdir, '*.wav')))[:NPADS]):
            data = load_wav_8bit(wpath)
            if len(data) & 1:                 # even length (keeps the pool word-aligned)
                data += b'\x80'
            members[k][i] = (DIR_SIZE + len(pcm), len(data))
            pcm += data

    out_b = bytearray()
    for k in range(NKITS):
        for i in range(NPADS):
            m = members[k][i] or (0, 0)
            out_b += struct.pack('>II', m[0], m[1])
    out_b += pcm
    open(out, 'wb').write(out_b)

    print('samples: pool=%d bytes (dir %d + pcm %d)' % (len(out_b), DIR_SIZE, len(pcm)))
    for k in range(NKITS):
        row = [members[k][i][1] if members[k][i] else 0 for i in range(NPADS)]
        if any(row):
            print('  kit %d:' % k, row)


if __name__ == '__main__':
    main()
