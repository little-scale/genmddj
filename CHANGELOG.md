# Changelog

All notable changes to genmddj. Versions increment by **0.01**.

## v0.12 — 2026-07-01

### Fixed
- **Noise pitched mode** — placing notes in the `NO` track now clocks the noise generator from
  tone 2 (periodic *and* white noise follow the pitch). It was silently ignored before.
- **`D` (delay) on a tone** — a delayed note played the wrong pitch (it looked like a transpose);
  the delayed note now sounds at its written pitch.
- **`K00` now truly kills the note** — silence + envelope off + stop the macro table, so nothing
  (including a table's VOL column) can revive it. Works in phrases and tables alike.
- **Macro table stopping early** — a table now runs independently of the volume envelope, so it
  keeps arping/driving through a fast decay and a note's tail instead of freezing when the volume
  hits zero (very visible with `DCY=0`).
- **`DCY=0`** is now a fast multi-step decay rather than an instant cut, avoiding a click.

### Changed
- **`X` command extended to the PSG** — it now caps the output level of the square and noise
  voices (0–15), not just FM, and is per-row (resets to full on the next note unless `X` is set).
- **`E` command is per-row** — the attack/decay re-slope applies only to its row and clears on the
  next note-on.
- **Editor defaults** — a new value in a table **V** column, and a new command (phrase B-tap insert
  or a blank table **CMD** cell), now inherit the **last** value entered (the CMD default carries
  both the letter *and* its parameter).
- **Double-tap** window widened 16 → 24 frames (~0.4 s), and a double-tap on an **empty** chain/
  phrase reference cell now mints a fresh **blank** (a double-tap on a populated cell still clones).
- **OPTIONS** — value column aligned at col 10, and **AUDITION** shows an on/off toggle box (like
  the LFO / FM AM switches) instead of ON/OFF text.
- **LIVE mode** — a track queued to stop at chain end (C+B a playing chain in SONG) now shows an
  **X** marker where its playhead triangle would be.

### Docs
- README Releases callout is version-agnostic and links `CHANGELOG.md`.

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
