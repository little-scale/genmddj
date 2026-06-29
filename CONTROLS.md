# CONTROLS.md

The genmddj button map, **as actually wired in `src/main.asm`** (snapshot 2026-06-27).
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
| **B + Start** | SYNC = IN/IN24 → arm **WAIT** for the incoming clock; otherwise = a plain Start |

## Editing — grid screens (PHRASE / CHAIN / SONG) and field screens

| Input | Action |
|---|---|
| **B** tap | Insert / edit / audition the cell under the cursor (repeats the last value). Grid/field screens only; field-only screens (PROJECT/OPTIONS/etc.) edit via B-hold+D-pad instead |
| **B-hold + D-pad** | Adjust the value under the cursor — L/R = small step (±1 / ±1 semitone), U/D = big step (octave / ±$10) |
| **B** double-tap | Paste (if a clipboard is armed for this screen). On reference cells (SONG chain#, CHAIN phrase#) with no clipboard: empty cell → mint the next free chain/phrase; populated → clone it (a SONG chain clone obeys OPTIONS **CLONE**: SLIM shares its phrases, DEEP copies them) |
| **B-hold + A** tap | Copy the field to the clipboard |

## Block select — grid screens (PHRASE / CHAIN / SONG)

| Input | Action |
|---|---|
| **A-hold + B** tap | Enter block-select (anchor at cursor) |
| *(in block mode)* **D-pad** | Extend the selection box |
| *(in block mode)* **B** | Copy the block, exit |
| *(in block mode)* **A** | Cut (copy + clear), exit |
| *(in block mode)* **C** | Cancel |
| **B** double-tap | Paste the block (rows anchor at the cursor; columns stay type-safe) |

## A-hold — navigate (CHAIN / PHRASE / SONG)

| Input | Action |
|---|---|
| **A-hold + Left / Right** | CHAIN / PHRASE: switch channel (which track's chain/phrase is shown) |
| **A-hold + Up / Down** | PHRASE: flip prev/next **phrase** (0–191) · CHAIN: flip prev/next **chain** (0–127) · SONG: page the 240-row view |

## C + B — context play

| Screen | Action |
|---|---|
| SONG (SONG mode) | Play the full song from the cursor row |
| SONG (LIVE mode) | See **LIVE mode** below — launch / stop the cursor's track |
| CHAIN | Solo this track's chain, from the cursor step |
| PHRASE | Solo this phrase |
| INSTR / FM | Solo the phrase/track you arrived from (replays the last PHRASE context — `cur_phrase`/`cur_chan`, e.g. after C+→ from a note) |
| FILES | Open / close the SAVE / LOAD / CLEAR / CANCEL sub-menu for the selected slot |

## LIVE mode (SONG screen, `MODE = LIVE`)

The SONG grid becomes a clip-launcher; the screen title reads **LIVE**.

| Input | Action |
|---|---|
| **C + B** on a populated cell | **Launch** that track from there. Quantized: transport stopped → starts now; running + that track silent → next master 16-row bar; running + that track playing → at the current chain's end (HOP-aware) |
| **C + B** on an empty cell *or* the track's currently-playing cell | **Quantized stop** (plays out the current chain, then silent) |
| **Start** | Launch every populated track on the cursor row |
| **B + Start** (SYNC = IN/IN24) | Arm WAIT for the incoming clock |
| **A-hold + Up / Down** | Page the 240-row view (one 16-row page at a time) |

A launched track plays its chain, advances down its column, and on an empty cell loops the top of that
contiguous chain group — independently, with its own playhead (silent/un-launched tracks show none).

## FILES — song library (C+Down from SONG)

A slot browser: the SRAM/FREE read-out, then — below the `—— SONGS NN ——` divider — the saved
songs (16 per page, `Pn/m`, each with its stored KB) followed by a trailing **`(EMPTY)`** slot.
Up to 32 songs. The action buttons live in a sub-menu (C+B), not on the screen.

| Input | Action |
|---|---|
| **Up / Down** | Move between slots (songs, then the `(EMPTY)` slot) |
| **B-hold + Left / Right** | Move the name cursor (the inverted character) across the 8 name chars |
| **B-hold + Up / Down** | Cycle the character under the cursor — the ring is `BLANK`-home: Up → A–Z then specials, Down → 0–9. On a saved slot this renames it live; the `(EMPTY)` slot reads `(EMPTY)` until your first keystroke (which starts a fresh name), becoming the new song's name on SAVE |
| **C-hold + B** tap | Open / close the action sub-menu for the selected slot |
| *(menu)* **Up / Down + B** | Run **SAVE** (store the working song), **LOAD** (load the slot — or on `(EMPTY)`, start a fresh blank project), **CLEAR** (delete the slot), **PURGE PH** / **PURGE CH** (working song: blank phrases/chains not reachable from the SONG so they drop out of the next save — tap twice to confirm, shows `FREED nn`), or **CANCEL** (close) |

The name is unified (`song_title`): it shows on PROJECT and on the SONG header, and is the slot
name on save. Transport **stops automatically** on SAVE/LOAD. A refused save (directory or SRAM
full) shows **FULL** by the FREE meter; a fresh cart is formatted on first boot; a load that
fails its checksum blanks to a known state. OPTIONS holds just the display/sync/clone settings
(VID / SYNC / PALETTE / CLONE).

## Per-screen field edits (B-hold + D-pad)

| Screen | Fields |
|---|---|
| **PROJECT** | TMPO / TSP / MODE / LFO. The song NAME is shown but **read-only** here — rename only on FILES. Save / load moved to FILES. |
| **OPTIONS** | VID / SYNC / PALETTE / **CLONE** (clone depth: SLIM = share phrases, DEEP = copy them). The song library moved to its own FILES screen — C+Down from SONG |
| **WAVE** | plain Left/Right = wave-step cursor; B-hold + D-pad = sample level |
| **INSTR / FM** | operator + voice parameters; A-hold + L/R also switches the instrument context. **B-tap auditions C-4 of the current instrument** on the track you came from — only while the transport is stopped (library buttons on row 1 still LOAD/SAVE) |
| **TABLE / GROOVE / ECHO / LFO** | their respective fields |

## Not yet wired (free for the taking)

- **A-tap alone** — intentionally unbound (A is a pure held-modifier). Mute/solo is set aside for now.
- **C + Start** — DESIGN's "full song from any screen"; currently unbound.
- **6-button X / Y / Z / Mode** — deferred (3-button is the baseline).
