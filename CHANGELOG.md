# Changelog

All notable changes to genmddj. Versions increment by **0.01**.

## v0.16 — 2026-07-08

### Added
- **MIDI note takeover (`SYNC: MIDI`) — now working on real hardware.** The headline: an
  external MIDI keyboard / DAW plays genmddj's ten voices live over the shared **ESP32-S3 link
  bridge**, with the sequencer stepped aside. The first ten MIDI channels map 1:1 onto the
  console voices (**1–6 → F1–F6**, **7–9 → T1–T3**, **10 → NO**), with velocity, pitch-bend and
  note-off (FM key-off / PSG release). Each voice keeps a console-side "current instrument" — a
  sticky stand-in for a PHRASE row's INSTR column — seeded on entry to `ch#−1` and changed live
  by **Program Change** (0–31 song pool / 32–63 ROM factory / 64–95 SRAM). **Hardware-verified
  on a Mega Drive 2**, and on the sibling **SMSGGDJ** over the same bridge. (MANUAL §13.)
- **On-screen MIDI monitor** (OPTIONS, in MIDI mode) — a live `MIDI RX nnnn` decoded-event
  counter + `LAST ss d1 d2` last-frame readout; the console half of the two-sided bring-up
  diagnostic.
- **CONT transition cues** — the SONG arrangement header shows a per-track `*` (flagged to
  carry) / `>` (bridging) marker beside each voice label, and the FILES divider shows
  `CUED nn IN xxx` then `MATCH IN nnn` while a live song swap is queued / gliding.
- **HELP command reference** — two new HELP pages listing every A–Z phrase/table command with
  its one-line description (generated from `cmd_hints.txt`).

### Changed
- **MIDI CLK is now driven push-pull** (matching SMSGGDJ), not open-drain — the fix that made
  takeover work on this MD2+S3 rig: open-drain's pull-up RC ramp meant the bridge missed most
  clock edges, so notes decoded as garbage. Also: per-channel default instruments seeded on
  MIDI entry; `midi_poll` re-asserts TR=output each frame; `MIDI_SETTLE` 8 → 12.

### Added
- **CONT — song-to-song continuity.** A LIVE-set performance layer: load the next song
  without stopping. Per-track **CONT flags** on SONG (toggle + `*` / `>` cues), a
  **beat-quantized live load** (arm now, fire on the downbeat), **beat-matched bridges**
  when entering a new song, a **tempo glide** (SLID length on PROJECT) that ramps between
  songs, and **FILES → LOAD / CUED** wiring. Boots OFF (a per-set choice).
- **HELP screen** (above TABLE) — a read-only, **paged button reference**. Open it from
  **any** screen by holding **A ~3 s**; the D-pad turns pages (with an `N/M` counter); the
  body is generated from an editable `help.txt`. First boot shows `HOLD A TO VIEW HELP`.
- **On-console hints** — the bottom row shows a one-line reminder for the item under the
  cursor: per **INSTR** field (per type + FM operator columns) and per **PHRASE/TABLE
  command**. Edited in `instr_hints.txt` / `cmd_hints.txt`; shared **OPTIONS → HINTS**
  toggle (default ON).
- **MIDI input (experimental)** — a 2-wire shift-in (`midi_poll`) feeding note-on/off for
  FM **and** PSG voices, selectable in **OPTIONS → SYNC**. IN24 clock-sync is
  hardware-verified; note-takeover is still being brought up on hardware.

### Changed
- **DAC sample rate doubled** — the Z80 tight-loop feed lifts PCM playback from ~5327 Hz to
  **10653 Hz** (M9), with a shrunk Timer-A flag-clear race window.
- **HELP is now data, not code** — generated from `help.txt` at build time.

### Fixed
- **Audition double-note** on hardware — an asymmetric pad debounce.
- **YM2612 post-write busy window** is guarded before the `$27` re-park (Z80).
- **TONE / KIT / NOISE** instruments no longer show phantom FM-operator columns
  (single-column fields).
- Pool indices are **sanitised on song load** (guards a corrupt save).

### Engine
- Up to **MAXPATCH** FM operator patches per tick (was 1).
- **E command** now re-slopes FM carriers (AR/RR) — the deferred FM half.
- Retired the vestigial `SCR_FM` screen id.

### Tools
- **`make test`** — a headless regression harness (DAC pacing, KIT end-stop, SCB delivery,
  boot smoke) + a **user-tools consistency checker**.
- New build-time generators: `makehelp.py`, `makehints.py`, `makecmdhints.py`.

## v0.14 — 2026-07-02

_(v0.13 skipped.)_

### Added
- **GROUP** (TONE instruments) — a TONE instrument played on **T1** can drive **T2** and **T3**
  from it, for fat sounds from a single melody line. Modes: **UNISON1/2** (±1/±2 register detune),
  **FIFTH**, **POWER** (fifth + octave), **OCTAVE1/2**, and **CHORD** (the `C` command sets the
  T2/T3 semitone offsets — high nibble T2, low nibble T3, latched). **RD1/RD2** attenuate the T2/T3
  voices below T1. T2/T3 follow T1's timing, envelope, sweep and vibrato. (MANUAL §5.)
- **Region-aware playback** — OPTIONS split the old (inert) region setting into **VIDEO**
  (NTSC/PAL/AUTO → refresh rate: tempo constant + VDP 224/240-line mode) and **CLOCK**
  (NTSC/PAL/AUTO → sound-chip crystal: PAL vs NTSC pitch tables for PSG, wavetable and FM).
  `AUTO` reads the console; the two axes are independent, so a **PAL-60 mod** (60 Hz video +
  PAL crystal) plays in time *and* in tune. Takes effect immediately. Hardware-verified.

### Changed
- **OPTIONS** — aligned the value column and spaced the list (blank rows after VIDEO and SYNC);
  **AUDITION** is a toggle box.
- **Instrument patcher** shows the patch index in **hex**, matching the console.
- Standardised the PSG square voices to **T1–T3** across the manual, docs and tools (matching the
  on-screen labels). `als2genmddj` still accepts legacy `S1`–`S3` in MML input.

### Docs
- MANUAL: a GROUP section; README notes manual emulator testing was done in Richard Bannister's
  macOS **Genesis Plus**.

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
