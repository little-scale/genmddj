# genmddj

<p align="center"><img src="art/genmddj.png" alt="genmddj"></p>

An **LSDJ-inspired music tracker for the Sega Mega Drive / Genesis**, driving the
**YM2612** FM synthesiser (6 × 4-operator + an 8-bit PCM DAC) and the **SN76489**
PSG (3 squares + noise), written in **68000 + Z80 assembly**. It's a **sibling
project** to **SMSGGDJ**, little-scale's Sega Master System / Game Gear music tracker.



> [!TIP]
> **Just want to play it?** **[v0.1 is out](../../releases/latest)** — grab the
> ready-to-flash `genmddj-v0.1.bin` from the [Releases](../../releases) page, no toolchain
> needed: drop the `.bin` on your flashcart or open it in an emulator.

> [!NOTE]
> **Work in progress** — under active development, so expect rough edges and shifting
> internals. It does run on real hardware, though: tested on NTSC and PAL **Sega Genesis, Mega
> Drive, and Nomad**, as well as in emulation via Genesis Plus. 

Ten voices: 6 FM (`F1`–`F6`; `F6` doubles as the PCM / sample host) + 3 PSG square
(`T1`–`T3`) + 1 PSG noise (`NO`).

## Quickstart

**Voices (10)** — `F1`–`F6` FM · `T1`–`T3` PSG square · `NO` PSG noise. `F6` also hosts
PCM samples / wavetables.

**Main Concepts** 
- Notes live within phrases, phrases live within chains, chains are put together to make a song
- Each vertical track corresponds to a sound chip channel (F1 - F6 are YM2612, T1-T3 and NO are SN76489)
- Tracks do not own instruments, phrases or chains but rather use these as structures to play out from
- There are six possible instrument types which can be used on the following tracks: 
FM (F1 - F6), Kit (F6), Wave (F6), Tone (T1 - T3), Noise (No), Perc (F3)

**Controls** — the *held* button picks the action:
- **D-pad** — move the cursor.
- **B** — tap = insert / edit · hold + D-pad = nudge the value (L/R small, U/D big) ·
  double-tap = paste · tap on a note = audition it.
- **A** (held) + D-pad = navigate within context: `A`+B = block-select · `A`+←/→ = switch channel · `A`+↑/↓ = page.
- **C** (held) + D-pad = navigate to new context (change screen). 
- **C + B** = play from the cursor (solo this screen).
- **Start** = play / stop the song (in LIVE, launch the cursor row).




**Screens** — there are 12 screens:

```
[O][P][ ][W][ ]
[S][C][P][I][T]
[F][G][ ][L][E]
```

Each screen is represented by a letter and this map of screens is navigated by C (held) + D-pad

 `SONG` arranges chains across the 10 tracks → `CHAIN` lists phrases →
`PHRASE` holds the notes. Build sounds in `INSTR` / `WAVE`, automate them in `TABLE` and `LFO`,
set the feel in `GROOVE`, add delay in `ECHO`, save/load in `FILES`, persistent settings in `OPTIONS` and project settings in `PROJECT`

**Make a sound in six steps:**

1. We start in the SONG screen. Insert a CHAIN in the SONG screen by tapping B on an empty cell in a track column 
2. C + right to move to the CHAIN screen to edit the inserted CHAIN by tapping B on an empty PHRASE cell
3. C + right to move to the PHRASE screen to edit the inserted PHRASE by tapping B on an empty NOTE cell. Each row inside of PHRASE represents a 1/16th note. 
4. To edit a note, select it then B + left / right will change the note by a semitone and B + up / down will change the note by an octave. 
5. Change how a given note sounds by changing the INSTRUMENT patch that plays that note by changing the IN column in PHRASE. 
6. To edit the INSTRUMENT patch of a given note, select that note in the IN column and then C + right to move to the INSTRUMENT screen


The full guide — every screen, the FM editor, the A–Z commands, sync — is in
**[MANUAL.md](MANUAL.md)**.

## Build

Requires [vasm](http://sun.hasenbraten.de/vasm/) (Motorola syntax — `vasmm68k_mot`)
and Python 3.

```sh
make            # -> build/genmddj.bin   (flash it, or run in any Mega Drive emulator)
```

`make run` launches the ROM in [mednafen](https://mednafen.github.io/). `make shot`
renders a headless screenshot via a small libretro harness — it expects the
`genesis_plus_gx` core in `tools/emu/` (fetched separately; not in the repo).

## How it works

The **68000** owns everything: the song data, the editor / UI / VDP, and the
per-tick sequencer engine. Each tick it computes the chip-register state it wants,
**diffs it against a 68k-held shadow**, packs *only the changes* into a small
**Sound Control Block**, and pushes that into the **Z80**'s local RAM over a short
bus grab. The Z80 is a pure chip servant — it flushes that write list to the YM2612
and PSG, and feeds the PCM DAC off the YM2612's Timer A. It holds no song state.

The FM / PSG voice model, the full screen set, the A–Z command set, save/load and sync
are all covered from the player's side in [MANUAL.md](MANUAL.md).

## Tools

A browser-based companion suite lives in [`user-tools/`](user-tools/): ROM patchers
(palette, **font**, the factory **wave** bank, the instrument bank, sample kits), a
save-file tool, and **`als2genmddj`** — convert Ableton Live `.als`, Standard MIDI
`.mid`, or **MML** text ⇄ a genmddj `.gmdj` song. See
[user-tools/README.md](user-tools/README.md).

## Status

**M1–M8 are built and hardware-verified on a real cartridge**; M9 / M11 / M12 are in
progress. Working today:

- The **68k → SCB → Z80** engine, with PSG + full 6-operator FM voices.
- The complete screen set: **SONG / CHAIN / PHRASE / INSTR / FM / TABLE / WAVE /
  GROOVE / ECHO / PROJECT / OPTIONS**.
- Grooves, the command set, copy / paste / clone.
- **Save / load** (verified on a real cart), DE-9 hardware **sync** (OUT / PULSE / IN / IN24;
  OUT↔IN is 1-clock-per-row, two-MD tested; IN24 = 24-PPQN for the Ableton Link bridge),
  **wavetable** synthesis + **ECHO**, and **LIVE mode** (the clip launcher).

See [MANUAL.md](MANUAL.md) for how to use it.

## Documentation

| Doc | What |
|---|---|
| [MANUAL.md](MANUAL.md) | The full user manual — controls, the screens, making a song, the instrument types, the FM editor, the A–Z command set, save/load, and sync. |
| [PALETTE.md](PALETTE.md) · [PRESETS.md](PRESETS.md) · [ALS.md](ALS.md) | The palette set, the factory presets, and the Ableton path. |

## Related projects

- **[SMSGGDJ](https://github.com/little-scale/smsggdj)** — the sibling tracker for the
  SEGA Master System / Game Gear that genmddj grew out of (shared data model, the entire
  PSG layer, grooves, the command set, and the native DE-9 sync).
- **[smsggdj-link-esp32](https://github.com/little-scale/smsggdj-link-esp32)** — ESP32
  firmware bridging **Ableton Link** to the trackers' DE-9 hardware sync (a XIAO ESP32-C3
  driving the `SYNC IN` line). genmddj's SYNC IN was hardware-verified against this.
- **[ares-link-sync](https://github.com/little-scale/ares-link-sync)** — an **ares**
  emulator fork that follows an Ableton Link clock in-emulator (frame-PLL'd, bar-quantized
  launch) — for testing Link sync without hardware.
- **[tri-pixel-editor](https://github.com/little-scale/tri-pixel-editor)** — the
  triangular-grid pixel-art editor the genmddj **logo / wordmark** was designed in.

## License

MIT — see [LICENSE](LICENSE). © 2026 Sebastian Tomczak (little-scale).

A sibling to SMSGGDJ, built on the work of the Mega Drive / Genesis homebrew community.
