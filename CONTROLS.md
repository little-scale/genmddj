# CONTROLS.md

The genmddj button map, **as actually wired in `src/main.asm`** (snapshot 2026-06-23).
This supersedes DESIGN §3's table where they differ — §3 still describes the older scheme
(Start = local-from-cursor, C+Start = full-song, B+C = cut). The core idea is unchanged:
the **held modifier selects the context — no simultaneous-press timing windows** (only paste
uses a double-tap). Pad: 3-button baseline (**A B C Start**); 6-button extras are deferred.

## Global — any screen

| Input | Action |
|---|---|
| **D-pad** | Move cursor (key-repeat) |
| **C-hold + D-pad** | Navigate the screen map, context-following (e.g. from PHRASE, C+← → the CHAIN holding it, again → that SONG cell; C+→ → that note's INSTR) |
| **Start** | Transport toggle. SONG mode = play the full song from the top; LIVE mode = launch the cursor row. Press again = stop |
| **B + Start** | SYNC = IN → arm **WAIT** for the incoming clock; otherwise = a plain Start |

## Editing — grid screens (PHRASE / CHAIN / SONG) and field screens

| Input | Action |
|---|---|
| **B** tap | Insert / edit / audition the cell under the cursor (repeats the last value). On PROJECT = trigger the action row |
| **B-hold + D-pad** | Adjust the value under the cursor — L/R = small step (±1 / ±1 semitone), U/D = big step (octave / ±$10) |
| **B** double-tap | Paste (if a clipboard is armed for this screen). On reference cells (SONG chain#, CHAIN phrase#) with no clipboard: empty cell → mint the next free chain/phrase; populated → clone it |
| **B-hold + A** tap | Copy the field to the clipboard |

## Block select — grid screens (PHRASE / CHAIN / SONG / TABLE)

| Input | Action |
|---|---|
| **A-hold + B** tap | Enter block-select (anchor at cursor) |
| *(in block mode)* **D-pad** | Extend the selection box |
| *(in block mode)* **B** | Copy the block, exit |
| *(in block mode)* **A** | Cut (copy + clear), exit |
| *(in block mode)* **C** | Cancel |
| **B** double-tap | Paste the block (rows anchor at the cursor; columns stay type-safe) |

## C + B — context play

| Screen | Action |
|---|---|
| SONG (SONG mode) | Play the full song from the cursor row |
| SONG (LIVE mode) | See **LIVE mode** below — launch / stop the cursor's track |
| CHAIN | Solo this track's chain, from the cursor step |
| PHRASE | Solo this phrase |

## LIVE mode (SONG screen, `MODE = LIVE`)

The SONG grid becomes a clip-launcher; the screen title reads **LIVE**.

| Input | Action |
|---|---|
| **C + B** on a populated cell | **Launch** that track from there. Quantized: transport stopped → starts now; running + that track silent → next master 16-row bar; running + that track playing → at the current chain's end (HOP-aware) |
| **C + B** on an empty cell *or* the track's currently-playing cell | **Quantized stop** (plays out the current chain, then silent) |
| **Start** | Launch every populated track on the cursor row |
| **B + Start** (SYNC = IN) | Arm WAIT for the incoming clock |
| **A-hold + Up / Down** | Page the 240-row view (one 16-row page at a time) |

A launched track plays its chain, advances down its column, and on an empty cell loops the top of that
contiguous chain group — independently, with its own playhead (silent/un-launched tracks show none).

## Per-screen field edits (B-hold + D-pad)

| Screen | Fields |
|---|---|
| **PROJECT** | TMPO / TSP / MODE / SLOT / LFO. **B** tap on a row = NEW · DEMO · SAVE · LOAD (NEW / DEMO / LOAD need a second confirming tap within ~1.5 s; "SURE? TAP AGAIN") |
| **OPTIONS** | VID / SYNC / PAL (SRAM line is read-only) |
| **WAVE** | plain Left/Right = wave-step cursor; B-hold + D-pad = sample level |
| **INSTR / FM** | operator + voice parameters; A-hold + L/R also switches the instrument context |
| **TABLE / GROOVE / ECHO / LFO** | their respective fields |

## Not yet wired (free for the taking)

- **A-tap alone** — DESIGN reserves it for mute/solo (tap = mute, hold = solo); not yet implemented.
- **C + Start** — DESIGN's "full song from any screen"; currently unbound.
- **6-button X / Y / Z / Mode** — deferred (3-button is the baseline).
