#!/usr/bin/env python3
"""Build the genmddj sample pool (kit directory + 8-bit PCM) from samples/kit NN/*.wav.

Pool layout (big-endian, 68k-native), labelled `sample_pool` in ROM. The 8-byte
magic lets the browser kit-patcher locate and rewrite the pool in a built ROM.

  header (16 bytes):
    +0  magic  "GMDJKIT1"
    +8  nkits  (1)
    +9  npads  (1)
    +10 rate   (u16, DAC sample rate)
    +12 reserved (4, zero)
  directory (nkits*npads members, 16 bytes each):
    +0  offset (u32, bytes from pool start to this pad's PCM)
    +4  length (u32, byte count; 0 = empty pad)
    +8  name   (8 ASCII, null-padded; display only)
  pcm: concatenated 8-bit *unsigned* samples (0x80 = silence) at `rate` Hz

The 68k reads a member directly (ROM is on its bus) and hands the Z80 the absolute
ROM pointer + length in the SCB DAC command; the Z80 streams it to YM2612 reg $2A.

    makesamples.py samples/ build/samples.bin
"""
import sys, os, re, glob, wave, struct
import numpy as np

MAGIC = b'GMDJKIT1'
NKITS = 16
NPADS = 16
DAC_RATE = 5327                 # YM2612 Timer-A DAC cadence (1024-TA=10); clock-defined, stable
HEADER = 16
MEMBER = 16
DIR_SIZE = NKITS * NPADS * MEMBER
POOL_BASE = HEADER + DIR_SIZE    # first PCM byte


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
    b = np.clip(np.round(v * 127) + 128, 0, 255).astype(np.uint8)   # 8-bit unsigned
    return bytes(b)
    # NB: no end-of-sample declick (DESIGN.md Q5) -- samples that end mid-waveform click
    # on stop; deferred until the runtime autofade can be validated on hardware.


def pad_name(path):
    base = os.path.splitext(os.path.basename(path))[0]
    stripped = re.sub(r'^\s*\d+\s*', '', base)        # drop a leading "NN " index
    base = stripped if stripped else base             # ...but keep pure-numeric chop names
    return base[:8]


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
            if len(data) & 1:
                data += b'\x80'
            members[k][i] = (POOL_BASE + len(pcm), len(data), pad_name(wpath))
            pcm += data

    out_b = bytearray()
    out_b += MAGIC + bytes([NKITS, NPADS]) + struct.pack('>H', DAC_RATE) + b'\x00' * 4
    for k in range(NKITS):
        for i in range(NPADS):
            off, ln, nm = members[k][i] or (0, 0, '')
            out_b += struct.pack('>II', off, ln) + nm.encode('ascii', 'replace').ljust(8, b'\x00')
    out_b += pcm
    open(out, 'wb').write(out_b)

    print('samples: pool=%d bytes (hdr+dir %d + pcm %d)' % (len(out_b), POOL_BASE, len(pcm)))
    for k in range(NKITS):
        row = [(members[k][i][2] if members[k][i] else '-') for i in range(NPADS)]
        if any(members[k]):
            print('  kit %d:' % k, row)


if __name__ == '__main__':
    main()
