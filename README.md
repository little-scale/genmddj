# genmddj

![genmddj](art/genmddj.png)

An **LSDJ-inspired music tracker for the Sega Mega Drive / Genesis**, driving the
**YM2612** FM synthesiser (6 × 4-operator + an 8-bit PCM DAC) and the **SN76489**
PSG (3 squares + noise), written in **68000 + Z80 assembly**. It's a **sibling
project** to **SMSGGDJ**, the author's shipped Master System / Game Gear tracker.

> [!NOTE]
> **Work in progress** — under active development, so expect rough edges and shifting
> internals. It does run on real hardware, though: tested on the **Sega Genesis, Mega
> Drive, and Nomad**, as well as in emulation.

Ten voices: 6 FM (`F1`–`F6`; `F6` doubles as the PCM / sample host) + 3 PSG square
(`S1`–`S3`) + 1 PSG noise (`NO`).

## Status

**M1–M8 are built and hardware-verified on a real cartridge**; M9 / M11 / M12 are in
progress. Working today:

- The **68k → SCB → Z80** engine, with PSG + full 6-operator FM voices.
- The complete screen set: **SONG / CHAIN / PHRASE / INSTR / FM / TABLE / WAVE /
  GROOVE / ECHO / PROJECT / OPTIONS**.
- Grooves, the command set, copy / paste / clone.
- **Save / load** (verified on a real cart), DE-9 hardware **sync** (OUT / PULSE / IN),
  **wavetable** synthesis + **ECHO**, and **LIVE mode** (the clip launcher).

See [PLAN.md](PLAN.md) for the M1–M12 milestone roadmap.

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

The full design contract — hardware constraints, the data model, the FM / PSG voice
model, the command set, the DAC, sync, and the save format — is in
[DESIGN.md](DESIGN.md).

## Tools

A browser-based companion suite lives in [`user-tools/`](user-tools/): ROM patchers
(palette, **font**, the factory **wave** bank, the instrument bank, sample kits), a
save-file tool, and **`als2genmddj`** — convert Ableton Live `.als`, Standard MIDI
`.mid`, or **MML** text ⇄ a genmddj `.gmdj` song. See
[user-tools/README.md](user-tools/README.md).

## Documentation

| Doc | What |
|---|---|
| [DESIGN.md](DESIGN.md) | The design contract — hardware, data model, the 68k/Z80 split, screens, commands, save format. |
| [PLAN.md](PLAN.md) | Vision + the M1–M12 milestone build order. |
| [SAVEFORMAT.md](SAVEFORMAT.md) | The SRAM / `.srm` / `.gmdj` save format. |
| [COMMANDS.md](COMMANDS.md) · [CONTROLS.md](CONTROLS.md) · [MANUAL.md](MANUAL.md) | The command set, the controller map, and the manual. |
| [MEGADRIVE.md](MEGADRIVE.md) · [PALETTE.md](PALETTE.md) · [PRESETS.md](PRESETS.md) · [ALS.md](ALS.md) | Hardware notes, the palette set, factory presets, and the Ableton path. |

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

## License

MIT — see [LICENSE](LICENSE). © 2026 Sebastian Tomczak (little-scale).

A sibling to SMSGGDJ, built on the work of the Mega Drive / Genesis homebrew community.
