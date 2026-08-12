#!/usr/bin/env python3
"""Focused validation and end-to-end audio tests for genmddj-player."""
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / "user-tools/player/genmddj-player"
CORE = ROOT / "tools/emu/genesis_plus_gx_libretro.dylib"
ROM = ROOT / "build/genmddj.bin"
FACTORY = ROOT / "build/fm_factory.bin"

DATA_SIZE = 23904
SONG_OFS, SONG_LEN = 256, 2400
PHRASE_OFS, NPHRASES, PHRASE_SIZE = 2656, 192, 64
CHAIN_OFS, NCHAINS, CHAIN_SIZE = 14944, 128, 32
INSTR_OFS, INSTR_SIZE = 19040, 64
GROOVE_OFS, GROOVE_LEN = 23136, 256


def make_test_song(path: Path) -> None:
    data = bytearray(DATA_SIZE)
    data[SONG_OFS:SONG_OFS + SONG_LEN] = b"\xff" * SONG_LEN
    data[SONG_OFS] = 0                         # row 0, F1 -> chain 0
    for phrase in range(NPHRASES):
        for row in range(16):
            off = PHRASE_OFS + phrase * PHRASE_SIZE + row * 4
            data[off:off + 4] = bytes((0xff, 0, 0, 0))
    data[PHRASE_OFS:PHRASE_OFS + 4] = bytes((48, 0, 0, 0))
    for chain in range(NCHAINS):
        for step in range(16):
            off = CHAIN_OFS + chain * CHAIN_SIZE + step * 2
            data[off:off + 2] = bytes((0xff, 0))
    data[CHAIN_OFS:CHAIN_OFS + 2] = bytes((0, 0))
    data[INSTR_OFS:INSTR_OFS + 32 * INSTR_SIZE] = b"\xff" * (32 * INSTR_SIZE)
    data[INSTR_OFS:INSTR_OFS + INSTR_SIZE] = FACTORY.read_bytes()[:INSTR_SIZE]
    data[GROOVE_OFS:GROOVE_OFS + GROOVE_LEN] = bytes((6,)) * GROOVE_LEN

    header = bytearray(32)
    header[:8] = b"GMDJSONG"
    header[8] = 1
    header[10:12] = DATA_SIZE.to_bytes(2, "big")
    header[12:20] = b"PLAYTEST"
    path.write_bytes(header + data)


def run(*args: str, expect=0, cwd=ROOT) -> subprocess.CompletedProcess:
    result = subprocess.run(
        [str(PLAYER), *args], cwd=cwd, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != expect:
        raise AssertionError(
            f"command returned {result.returncode}, expected {expect}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def wav_energy(path: Path) -> tuple[int, int, int]:
    with wave.open(str(path), "rb") as audio:
        assert audio.getnchannels() == 2
        assert audio.getsampwidth() == 2
        frames = audio.getnframes()
        raw = audio.readframes(frames)
        energy = sum(abs(int.from_bytes(raw[i:i + 2], "little", signed=True))
                     for i in range(0, len(raw), 2))
        return frames, audio.getframerate(), energy


def main() -> None:
    if not CORE.exists():
        print("SKIP: genesis_plus_gx libretro core is not present")
        return
    with tempfile.TemporaryDirectory(prefix="genmddj-player-") as tmp_name:
        tmp = Path(tmp_name)
        song = tmp / "test.gmdj"
        make_test_song(song)

        result = run("--validate", str(song))
        assert "title=\"PLAYTEST\"" in result.stdout

        bad = tmp / "bad.gmdj"
        bad.write_bytes(b"not a song")
        run("--validate", str(bad), expect=2)

        mix = tmp / "mix.wav"
        run("--seconds", "0.5", "--output", str(mix), str(song), cwd=PLAYER.parent)
        frames, rate, energy = wav_energy(mix)
        assert rate == 44100
        assert frames > rate // 3, (frames, rate)
        assert energy > 1000, "autoplay render was silent"

        for requested_rate in (48000, 96000):
            converted = tmp / f"mix-{requested_rate}.wav"
            run("--seconds", "0.25", "--sample-rate", str(requested_rate),
                "--output", str(converted), str(song))
            converted_frames, converted_rate, converted_energy = wav_energy(converted)
            assert converted_rate == requested_rate
            assert requested_rate // 5 < converted_frames < requested_rate // 3
            assert converted_energy > 1000, f"{requested_rate} Hz render was silent"

        run("--sample-rate", "88200", str(song), expect=1)

        stems = tmp / "stems"
        run("--seconds", "0.25", "--sample-rate", "48000", "--stems", str(stems), str(song))
        expected = ["F1", "F2", "F3", "F4", "F5", "F6-DAC", "T1", "T2", "T3", "NO"]
        assert all((stems / f"{name}.wav").exists() for name in expected)
        _, f1_rate, f1_energy = wav_energy(stems / "F1.wav")
        _, f2_rate, f2_energy = wav_energy(stems / "F2.wav")
        assert f1_rate == f2_rate == 48000
        assert f1_energy > 1000, "F1 stem was silent"
        assert f2_energy < f1_energy // 20, "F1 leaked materially into the F2 stem"

    print("PASS: .gmdj validation, ROM autoplay, stereo render, and 10 voice stems")


if __name__ == "__main__":
    main()
