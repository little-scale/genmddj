#!/usr/bin/env python3
"""Build a compact ten-channel GENMDDJ player demonstration song."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
DATA_SIZE = 23904
SONG_OFS, SONG_LEN = 256, 2400
PHRASE_OFS, NPHRASES, PHRASE_SIZE = 2656, 192, 64
CHAIN_OFS, NCHAINS, CHAIN_SIZE = 14944, 128, 32
INSTR_OFS, INSTR_SIZE = 19040, 64
GROOVE_OFS, GROOVE_LEN = 23136, 256


def psg_instrument(kind: int, name: str, hold: int, decay: int, *, mode=0, rate=0) -> bytes:
    record = bytearray(INSTR_SIZE)
    record[0] = kind
    record[6] = 15
    record[7] = 15
    record[8] = 15                 # PSG peak volume
    record[9] = 0                  # instant attack
    record[10] = hold
    record[11] = decay
    record[14] = 0x32              # gentle vibrato
    record[48] = 0xff              # no macro table
    if kind == 4:
        record[14] = 0
        record[18] = mode
        record[19] = rate
    record[54:62] = name.upper().encode("ascii")[:8].ljust(8, b" ")
    return bytes(record)


def build(output: Path) -> None:
    factory_path = ROOT / "build/fm_factory.bin"
    if not factory_path.exists():
        raise SystemExit("build/fm_factory.bin is missing; run `make player` first")
    factory = factory_path.read_bytes()
    if len(factory) < 6 * INSTR_SIZE:
        raise SystemExit("factory FM bank is incomplete")

    data = bytearray(DATA_SIZE)
    data[2] = 0                    # project groove 0
    data[SONG_OFS:SONG_OFS + SONG_LEN] = b"\xff" * SONG_LEN
    for channel in range(10):
        data[SONG_OFS + channel] = channel

    for phrase in range(NPHRASES):
        for row in range(16):
            off = PHRASE_OFS + phrase * PHRASE_SIZE + row * 4
            data[off:off + 4] = bytes((0xff, 0, 0, 0))
    for chain in range(NCHAINS):
        for step in range(16):
            off = CHAIN_OFS + chain * CHAIN_SIZE + step * 2
            data[off:off + 2] = bytes((0xff, 0))
    for channel in range(10):
        off = CHAIN_OFS + channel * CHAIN_SIZE
        data[off:off + 2] = bytes((channel, 0))

    patterns = [
        {0: 36, 4: 36, 8: 43, 12: 34},
        {0: 48, 4: 55, 8: 53, 12: 51},
        {0: 60, 3: 63, 6: 67, 9: 70, 12: 67, 15: 63},
        {2: 72, 6: 74, 10: 75, 14: 74},
        {0: 43, 8: 50},
        {4: 55, 12: 60},
        {0: 60, 2: 62, 4: 64, 6: 67, 8: 69, 10: 67, 12: 64, 14: 62},
        {0: 48, 4: 55, 8: 53, 12: 55},
        {2: 72, 6: 72, 10: 74, 14: 72},
        {0: 48, 2: 50, 4: 48, 6: 50, 8: 48, 10: 50, 12: 48, 14: 50},
    ]
    for channel, pattern in enumerate(patterns):
        for row, note in pattern.items():
            off = PHRASE_OFS + channel * PHRASE_SIZE + row * 4
            data[off:off + 4] = bytes((note, channel, 0, 0))

    data[INSTR_OFS:INSTR_OFS + 32 * INSTR_SIZE] = b"\xff" * (32 * INSTR_SIZE)
    for channel in range(6):
        record = bytearray(factory[channel * INSTR_SIZE:(channel + 1) * INSTR_SIZE])
        record[3] = (2, 1, 3, 2, 1, 3)[channel]  # alternating L, R, centre
        data[INSTR_OFS + channel * INSTR_SIZE:INSTR_OFS + (channel + 1) * INSTR_SIZE] = record
    instruments = (
        psg_instrument(3, "LEADPSG", 2, 2),
        psg_instrument(3, "BASSP SG".replace(" ", ""), 3, 2),
        psg_instrument(3, "PULSEPSG", 1, 1),
        psg_instrument(4, "DRUMNOIS", 1, 2, mode=0, rate=1),
    )
    for index, record in enumerate(instruments, 6):
        data[INSTR_OFS + index * INSTR_SIZE:INSTR_OFS + (index + 1) * INSTR_SIZE] = record
    data[GROOVE_OFS:GROOVE_OFS + GROOVE_LEN] = bytes((6,)) * GROOVE_LEN

    header = bytearray(32)
    header[:8] = b"GMDJSONG"
    header[8] = 1
    header[10:12] = DATA_SIZE.to_bytes(2, "big")
    header[12:20] = b"PLYRDEMO"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(header + data)
    print(f"wrote {output} ({len(header) + len(data)} bytes)")


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "user-tools/player/song.gmdj"
    build(target)
