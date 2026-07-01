# Changelog

All notable changes to genmddj. Versions increment by **0.01**.

## v0.11 — 2026-07-01

### Fixed
- **Hung / ringing notes on stop** — stopping the transport (Start or C+B) now silences every
  voice: FM key-off on all six channels, all four PSG voices to zero, and the wave DAC feed
  stopped. Previously a keyed-on note (especially an instrument held with `HLD=$F`) or a PSG
  voice could ring on after Stop.
- **PROJECT master transpose (TSP)** now actually transposes the song — it was editable and
  saved, but never applied to the notes.

### Changed
- **FM editor:** the operator **AM** switch moved to the end of the operator row and now shows
  the same on/off toggle box (`{`/`}`) as the LFO screens — it was a digit sitting in the
  middle of the envelope.
- **Splash** shortened to ~2.0 s (PAL) / ~1.7 s (NTSC). Start still skips it.
- **PERC** (YM2612 CH3 special-mode percussion) confirmed on real hardware — no longer flagged
  experimental.

### Tools (`user-tools/`)
- **Save tool:** auto-detects and gunzips gzipped saves (Genesis Plus / Bannister battery RAM)
  on load, and a new **gzip output** option writes them back — so a save round-trips between a
  flashcart `.srm` and an emulator `.sav`. Layout detection now keys on the `GMD1` directory
  signature; the config block reads/writes at the current offset; VID/SYNC labels corrected.
- **Bank editor:** brought up to the current save format — `GMD1` layout detection, gzip in/out,
  and a faithful save that preserves config + songs while editing the SRAM instrument bank.
- **Wave editor:** fixed the `.gmdj` data-size / waves offset (it was rejecting current songs as
  "built for a different version").
- **de-re-interleaver:** sanity readout updated to the current save format.

### Docs
- Expanded README Quickstart (controls, the data model, the screen map, a six-step walkthrough),
  user-tools data-flow diagrams, and corrected `PRESETS.md` record-tail offsets.

## v0.1 — 2026-06-30

First public release — the full tracker: the 68k → SCB → Z80 engine, PSG + 6-operator FM voices,
the complete screen set (SONG / CHAIN / PHRASE / INSTR / FM / TABLE / WAVE / GROOVE / ECHO /
PROJECT / OPTIONS), grooves, the A–Z command set, samples + wavetables + ECHO, LIVE mode,
save/load (hardware-verified on a real cartridge), and DE-9 sync.
