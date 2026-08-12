# GENMDDJ Player

`genmddj-player` renders an extracted `.gmdj` song through the real GENMDDJ ROM,
Z80 driver, and a libretro Mega Drive emulator core. It does not translate or
reimplement the tracker engine.

The initial player is an offline renderer. It produces the console's interleaved
stereo output as a standard 16-bit PCM WAV and can repeat the deterministic render
for each of the ten hardware voices.

## Build

From the repository root:

```sh
make player
```

Then either run it from the repository root as shown below, or from this folder:

```sh
cd user-tools/player
./genmddj-player -r 48000 -o song.wav song.gmdj
```

The `./` is required because macOS shells do not search the current directory for
commands. The player locates the repository ROM and emulator core automatically.

The default setup expects the same separately obtained Genesis Plus GX libretro
core used by the existing headless tests:

```text
tools/emu/genesis_plus_gx_libretro.dylib
```

Use `--core FILE` for another compatible core or platform filename.

The player explicitly selects Genesis Plus GX's MAME YM2612 implementation by
default and its built-in SN76496 PSG implementation. For the more CPU-intensive
cycle-accurate Nuked OPN2 path, add `--ym2612 nuked`.

## Render

Original stereo mix, 30 seconds by default:

```sh
user-tools/player/genmddj-player user-tools/player/song.gmdj
```

Choose the duration and output:

```sh
user-tools/player/genmddj-player --seconds 90 --output song.wav user-tools/player/song.gmdj
```

Choose a 44.1, 48, or 96 kHz WAV output rate (the same option applies to stems):

```sh
user-tools/player/genmddj-player --sample-rate 48000 --output song-48k.wav user-tools/player/song.gmdj
user-tools/player/genmddj-player --sample-rate 96000 --stems stems-96k user-tools/player/song.gmdj
```

Genesis Plus GX supplies the emulated console mix at its native frontend rate
(normally 44.1 kHz). The player resamples that stereo stream to the requested WAV
rate; YM2612, PSG, sequencer, and console clocks remain unchanged.

Select the Nuked YM2612 core for an offline high-accuracy render:

```sh
user-tools/player/genmddj-player --ym2612 nuked --output song-nuked.wav user-tools/player/song.gmdj
```

Render ten hardware-voice stems:

```sh
user-tools/player/genmddj-player --seconds 90 --stems stems user-tools/player/song.gmdj
```

Render the original mix and stems together:

```sh
user-tools/player/genmddj-player -s 90 -o song.wav --stems stems user-tools/player/song.gmdj
```

Validate a container without loading the ROM or emulator:

```sh
user-tools/player/genmddj-player --validate user-tools/player/song.gmdj
```

Run the focused end-to-end test:

```sh
make player-test
```

The player folder includes `song.gmdj`, a one-pattern demo
that exercises all six FM voices, all three PSG tone voices, PSG noise, and
alternating YM2612 pan. Regenerate it after changing the factory instrument bank:

```sh
make player-demo
```

## Output model

The original mix preserves the emulator's stereo output, including YM2612 pan.
PSG voices retain the Mega Drive's native common PSG placement.

Stem files are named:

```text
F1.wav  F2.wav  F3.wav  F4.wav  F5.wav  F6-DAC.wav
T1.wav  T2.wav  T3.wav  NO.wav
```

They are stereo WAVs so YM pan remains meaningful. The stem identity is the
destination hardware voice: an echo copied to another channel belongs to that
destination channel's stem, and KIT/WAVE DAC playback belongs to `F6-DAC`.

GENMDDJ SONG blocks loop rather than producing an end-of-file event, so the
renderer uses an explicit duration. Rendering begins at the song's first emulated
sequencer frame; no splash or menu automation is involved.

## Host/ROM handshake

The host constructs a temporary linear emulator SRAM image containing the `.gmdj`
payload as directory song zero. A private `PLY1` marker and 10-bit render mask in
unused config bytes ask the ROM to load it, force internal-clock SONG mode, skip the
splash, and start playback. Ordinary SRAM images do not contain this marker and boot
exactly as before.
