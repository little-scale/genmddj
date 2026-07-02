# genmddj — User Manual

An LSDJ-inspired music tracker for the **Sega Mega Drive / Genesis**. It drives the
console's two sound chips — the **YM2612** (six 4-operator FM voices plus an 8-bit PCM
sample channel) and the **SN76489 PSG** (three squares and a noise channel) — from just
the D-pad and three buttons.

Build the ROM with `make` → `build/genmddj.bin`, then run it on a flashcart (Mega
EverDrive) or in an emulator. Nothing loads or plays until you ask.

> genmddj is a port of **SMSGGDJ**, the author's Master System / Game Gear tracker, so
> if you know that one most of this will feel familiar — the data model, the modifier-key
> control scheme, tables, grooves and sync all carry over. What's new on the Mega Drive:
> the full **FM voice editor**, **PCM samples + wavetables on the YM2612 DAC**, real
> per-channel FM stereo, ten voices, and a roomier 40-column screen.

---

## 1. Getting started

1. Put `genmddj.bin` on your flashcart's SD card, or open it in an emulator.
2. On boot you'll see the genmddj splash (with the build stamp), then the tracker opens
   on a fresh song. A new song comes preloaded with the **factory instruments**, so it
   can make sound right away.
3. Drop a note or two in a **PHRASE**, point a **CHAIN** and the **SONG** screen at it,
   and press **Start**.

The ten voices are:

- **F1–F6** — the six **YM2612 FM** voices. **F6** doubles as the host for PCM samples
  and wavetables (the DAC), so when a sample plays, F6's FM voice steps aside.
- **T1–T3** — the three **SN76489 PSG square** voices.
- **NO** — the PSG **noise** voice (also used for drum kits and pitched periodic-noise bass).

---

## 2. The controls

genmddj uses the **D-pad**, **A**, **B**, **C**, and **Start**. The trick — inherited
from SMSGGDJ — is that the buttons are **modifiers**: whichever one you're *already
holding* when you press another decides the action. There are **no simultaneous-press
timing windows** to nail (only *paste* uses a quick double-tap).

Think of it as:

- **B = the item button** — insert, edit, audition a note or value.
- **A = a held modifier** — block-select, and switching channel / page.
- **C = the project / navigation button** — move between screens, and play-from-here.
- **Start = transport** — play / stop.

| You do this | It does this |
|---|---|
| **D-pad** | Move the cursor (hold to repeat) |
| **B** tap | **Insert / edit / audition** the cell under the cursor — repeats the last value you entered for that column |
| **B** hold + D-pad | **Edit** the value under the cursor. Left/Right = small step (±1 / ±1 semitone); Up/Down = big step (±octave / ±$10) |
| **B** double-tap | **Paste** the clipboard here. On a *reference* cell (a SONG chain# or CHAIN phrase#) with nothing copied: an *empty* cell **mints** the next free chain/phrase; a *populated* cell **clones** it (see *Cloning*) |
| **B** hold + **A** tap | **Copy** the field under the cursor to the clipboard |
| **A** hold + **B** tap | Enter **block select** (grid screens — see below) |
| **A** hold + Left/Right | Switch **channel** — which track's CHAIN/PHRASE you're looking at |
| **A** hold + Up/Down | Flip to the prev/next **phrase** (PHRASE) or **chain** (CHAIN); **page** the view (SONG) |
| **C** hold + D-pad | **Move between screens** (the screen map, §3) — context-following |
| **C** + **B** | **Play from here / solo** the current thing (§3). On FILES it opens the action menu |
| **Start** | **Play / stop.** SONG mode plays the whole song from the top; LIVE mode launches the cursor row |
| **B** + **Start** | If SYNC = IN/IN24, arm **WAIT** for the incoming clock; otherwise a plain Start |

You never have to time two simultaneous presses.

### Block select (copy / cut a region)

On **SONG**, **CHAIN** or **PHRASE**: **hold A, then tap B**. You enter **block select**
anchored at the cursor.

- **D-pad** stretches the selection box.
- **B** = **copy** the block and exit.
- **A** = **cut** (copy + clear) and exit.
- **C** = cancel.

Then **double-tap B** to paste: the block drops in at the cursor, and each column lands
back on its own column type, so nothing gets scrambled.

### Transport: full-song vs play-from-here

There are two ways to start sound, and they differ from SMSGGDJ:

- **Start** plays the **whole song from the top** (all ten tracks) — your master transport.
- **C + B** plays **from where you are**, so you can audition a section while you work:
  - **SONG** — plays the cursor's **contiguous block**, snapped to its **top** and **looping**
    it. (A *block* is a run of rows with no fully-empty row in it — see §4. So with the cursor
    anywhere in a rows-2–4 block it plays from row 2 and loops 2–4.)
  - **CHAIN** — solos that track's chain from the cursor step.
  - **PHRASE** — solos that phrase.
  - **INSTR** — replays the phrase/track you arrived from (handy after drilling in from a note).

Press **Start** again to stop.

### Auditioning notes as you write

On **PHRASE**, while the transport is **stopped**, inserting a note or scrubbing its pitch
— **or B-tapping the instrument column** — **prelistens** the row (its note + instrument)
on that track. On **INSTR**, **B-tap** auditions **C-4** of the current instrument. Both
are gated by **OPTIONS → AUDITION** (default **ON**).

---

## 3. The screens

Hold **C** and press the D-pad to move around this map (it follows context — e.g. from a
PHRASE, `C+←` goes to the CHAIN that holds it, again to that SONG cell; `C+→` goes to that
note's INSTR):

```
   OPTIONS  PROJECT                     WAVE
   SONG     CHAIN    PHRASE    INSTR     TABLE
   FILES    GROOVE             FM LFO    ECHO
```

Navigation stops at the edges; it doesn't wrap. A mini-map in the top-right of every
screen highlights where you are. The top bar shows the screen name, song title, BPM, play
state, sync status and the position `SS:CC:PP` (song row : chain step : phrase row). The
right margin shows the ten channel activity meters, the current octave, and the current
instrument.

- **SONG** — the arrangement: ten columns of chain numbers (F1–F6, T1–T3, NO), one per
  voice, with a per-track playhead.
- **CHAIN** — a list of phrases (each with a transpose), played in order.
- **PHRASE** — 16 steps of note / instrument / command. The heart of it.
- **INSTR** — design one instrument. For an **FM** instrument this screen *is* the full
  FM voice editor (§6).
- **FM LFO** — the software LFO bank that modulates FM voices (below INSTR).
- **TABLE** — a 16-row automation sequencer an instrument can run.
- **GROOVE** — swing and timing.
- **WAVE** — draw the 16 wavetable shapes (above INSTR).
- **ECHO** — a tempo-synced delay (below TABLE).
- **PROJECT** — this song: tempo, transpose, mode, default groove/LFO; the song name
  (read-only here — rename on FILES).
- **FILES** — save, load and manage songs on the cartridge (below SONG).
- **OPTIONS** — this machine: video region, sync, palette, clone depth, audition.

---

## 4. Making a song

genmddj is built in layers, smallest first — the LSDJ idea:

1. **PHRASE** — write a short pattern: 16 steps, each a note, an instrument number, and
   optionally a command. Tap **B** on an empty step to drop the current instrument's note;
   **B**-hold + D-pad to change it. ↑↓ moves between steps (wraps F→0); ←→ moves between
   the NOTE / INSTR / CMD / PRM columns.
2. **CHAIN** — list the phrases you want, one per row, in order. Add a **transpose** in the
   right column to reuse a phrase a few semitones up or down.
3. **SONG** — place chains into the ten track columns, row by row, to build the
   arrangement. Each track reads down its own column.

**Switching which track you're editing:** on CHAIN or PHRASE, **A-hold + Left/Right**
flips between the ten voices' chains/phrases.

**How a column plays:** each track plays its chains down the SONG column and, when it hits
an empty cell, **loops back to the top of its current contiguous block** (the run of filled
cells it's in). So a gap-free column plays whole and loops; an empty cell is a section break,
and the blocks above/below it loop separately. Tracks loop independently, so columns of
different lengths create polymeters. **Start** begins every column at the very top (row 0);
**C+B** begins at the cursor's block (§2). (In **LIVE** mode the SONG grid is a clip
launcher — §9.)

### Quick duplicates and cloning

A SONG cell holds a **chain number**, a CHAIN cell holds a **phrase number** — they're
references, so:

- **B tap** on an empty reference cell inserts the **last** chain/phrase number.
- **B double-tap** on an empty reference cell **mints the next free** (blank) chain/phrase.
- **B double-tap** on a *populated* reference cell **clones** it into a fresh slot and
  repoints the cell at the copy, so editing it leaves the original alone.

**OPTIONS → CLONE** sets how a SONG chain clones:

- **SLIM** (default) — the new chain reuses the **same phrases** (sharing them). Cheap;
  good for the same melody re-arranged or transposed. Editing a shared phrase changes
  every chain that uses it.
- **DEEP** — also copies every phrase the chain uses, so the clone is fully independent
  (more phrase slots).

A CHAIN phrase clone is always an independent copy. If there's no free slot (or DEEP
won't fit), nothing is cloned.

**Tidy up before saving:** on FILES, **PURGE PH** / **PURGE CH** blank phrases/chains that
aren't reachable from the SONG, so they drop out of the next save (§8).

---

## 5. Instruments

Every instrument has a **TYPE**, set on the INSTR screen. Put an instrument's number next
to a note in a PHRASE to play that note with that sound. The six types:

- **FM** — a full **YM2612 four-operator** voice. Plays on F1–F6. The flagship type, with
  its own editor (§6).
- **TONE** — a **PSG square** wave. Plays on T1–T3. Volume, an AHD volume envelope,
  transpose, vibrato / pitch-sweep / tremolo, and an optional table. (Ports from SMSGGDJ.)
- **NOISE** — the **PSG noise** voice (NO). White or periodic noise, at fixed rates or
  **pitched** (which borrows T3 to tune it — great for periodic-noise bass).
- **KIT** — a **sample drum kit** on the YM2612 DAC (hosted on F6). The **note picks the
  pad** (positionally: pad 0 = kick, 1 = snare, 2 = hat, …). The **KIT** field chooses
  which ROM kit (e.g. 808 / 909 / C78 / 606 / speech), and a **RATE** plays it at
  1× / 2× / 4× / ½× (the `S` command overrides per note).
- **WAVE** — a **wavetable** voice on the DAC (F6). Pick one of the 16 user waves you draw
  on the WAVE screen; pitched melodically.
- **PERC** — YM2612 **CH3 special-mode percussion**: F3's four operators tuned
  independently for metallic/inharmonic percussion. (Advanced; hardware-verified.)

A new song's instruments come from the **factory bank**. You can edit any of the 32 song
instruments freely; **LOAD** pulls a factory or user-bank instrument into a song slot, and
**SAVE-TO-BANK** stashes a working instrument to your cross-song user library (these
soft-action fields live on the INSTR screen and work for every type).

### INSTR fields (common)

Timing is in **ticks** — one tick = one video frame (1/60 s NTSC, 1/50 s PAL). Volume is
the 0–F musical scale.

- **VOL** `0`–`F` — peak / hold level (`F` = loudest). On FM it scales the **carrier**
  operator's level; on PSG it sets attenuation.
- **ATK / HLD / DCY** `0`–`F` — a software **AHD** envelope (PSG voices): ramp up (attack),
  hold at VOL, ramp down (decay). On **FM**, the chip's own per-operator envelope owns the
  shape — here **HLD** sets the key-off timing only (**`F` = hold until the next note**),
  and ATK/DCY don't apply.
- **TSP** — transpose this instrument ±semitones.
- **TBL / TBL SPD** — a table to run, and its speed. `1`–`F` = step one row every N ticks;
  **`0`** = step one row **per played note** (the row carries across notes — good for arps
  against the phrase). See §7.

Type-specific fields (vibrato/sweep/tremolo on PSG, the noise MODE/RATE, the KIT/RATE,
the WAVE selector) appear only for the types that use them. A command in a PHRASE overrides
the matching field for that note.

### GROUP — stacking T2/T3 onto T1 (TONE only)

A **TONE** instrument played on **T1** can take over **T2** and **T3** and drive them from
T1 — fat detuned unisons, fifths, octaves and chords, all from a single melody line. Set it
with the **GROUP** field on the TONE instrument; when it's not OFF, two extra fields **RD1 /
RD2** appear below it. T2/T3 then follow T1's timing, envelope, sweep and vibrato, and their
own phrase notes are ignored while the group is active (leave those columns empty). It only
engages on **T1** — the same instrument played on T2 or T3 sounds as a normal tone.

| GROUP | T2 | T3 |
|---|---|---|
| **OFF** | — | — (all three independent) |
| **UNISON1 / 2** | T1 period **+1 / +2** | period **−1 / −2** (detuned unison) |
| **FIFTH** | a fifth above T1 | silent |
| **POWER** | a fifth above | an octave above |
| **OCTAVE1** | an octave above | silent |
| **OCTAVE2** | an octave above | an octave **below** |
| **CHORD** | `C` high nibble | `C` low nibble (see below) |

UNISON detunes by nudging the raw 10-bit tone-counter register, so it's a gentle few-cents
shimmer low down and spreads wider toward the top of the range — chip character; pick the
level that suits your register.

**RD1 / RD2** drop T2 / T3 below T1's level (`0` = same as T1, `F` = silent), echo-style —
so a two/three-voice stack doesn't overpower the mix.

**CHORD** is driven by the **`C` command** on T1's phrase: the two nibbles are semitone
offsets — **high = T2, low = T3**, and `0` in a nibble keeps that voice silent. `C 47` = T2
+4 (major third) and T3 +7 (fifth), a major triad over T1's root. The chord **latches** (it
holds across the following notes until you change it, so the command column stays free for
other commands); `C 00` clears it. In CHORD mode `C` no longer arps — T1 stays on its root.

---

## 6. The FM editor (INSTR, FM type)

When an instrument's TYPE is **FM**, the INSTR screen becomes the full YM2612 voice
editor. Navigate with the plain D-pad; **B-hold + D-pad** edits the field under the cursor;
**B tap** auditions the patch.

**Voice header**

- **ALGO** `0`–`7` — operator routing. genmddj draws an **operator-routing diagram** and
  marks the **carrier** rows in the grid, so you can see which operators are the audible
  output (what VOL / `X` scale) vs the modulators (the timbre, moved by `U`).
- **FB** `0`–`7` — operator-1 self-feedback.
- **LFO** `0`–`7` — the chip-wide YM2612 LFO **rate**. This is a **global** field: it's one
  rate shared by *every* FM voice (stored with the song), and the per-note `M`/`V`/`Y`
  commands and the AMS/FMS depths only do anything when it's non-zero.
- **AMS / FMS** — this voice's LFO amplitude / frequency sensitivity.
- **PAN** — L / R / LR (real per-channel FM stereo; the `O` command sets it per note).

**The 4-operator grid** — one row per operator, in YM2612 register order (**OP1, OP3, OP2,
OP4** — that's the chip's true slot order, so each row reads as the operator it drives):

- **DT / MUL** — detune / frequency multiple.
- **TL** `0`–`7F` — total level (operator level). The carrier op's TL is the audible
  volume (gated by VOL); a modulator's TL is its brightness.
- **RS/KS, AR** — rate scaling / attack rate.
- **D1R / D2R** — first decay / second (sustain) decay rate.
- **SL / RR** — sustain level / release rate.
- **AM** — enable this operator's amplitude modulation from the LFO.

**INIT** resets the patch to a basic sine. Because the engine reads instruments straight
from RAM on every note, you can **leave the song playing and edit a patch live** — every
change is heard on the next trigger, no stop/start.

**FM LFO screen** (below INSTR): a software LFO bank that can modulate FM voices beyond the
chip's single global LFO — assign an LFO to a channel and set its parameter, rate and
depth. The channel column reads F1–F6.

---

## 7. Wavetables and tables

### Wavetables (WAVE screen)

**16 user waves, 32 steps each, 8-bit.** The screen is an etch-a-sketch: all 32 steps
shown as centred bars around a centre line (`$80`). The YM2612 DAC is true 8-bit linear,
so the drawn byte plays directly.

| Gesture | Action |
|---|---|
| Plain ←→ | move the step cursor (no draw) |
| **B-hold + ↑↓** | raise / lower the current step (the pen) |
| **B-hold + ←→** | **draw** — step to the neighbour and set it to the pen level (sweep to paint ramps/flats) |
| **B-hold + C** | **stamp a preset** (sine → tri → saw → square → 25% → 12.5% → organ → random) |
| **C-hold + ←→** | select which wave (0–15) |
| Start / C+B | audition the wave as a held note |

The drawn wave is the raw base shape, shared across instruments; a WAVE instrument's volume
gates it.

### Tables (TABLE screen)

A **table** is a 16-row automation strip an instrument runs while a note holds — a **VOL**
column, a **TSP** (transpose, for arpeggios) column, and a **CMD** column. Assign one to an
instrument (TBL / TBL SPD), or trigger one with the `A` command. Row 0 selects which of the
**32** tables you're editing.

- All three columns are live on **FM and PSG**: TSP arps (feeds the PSG period / FM
  F-number), VOL overrides the channel volume per row (`--` = no change), and CMD runs the
  row's command once on entry through the **same** executor as a phrase command.
- **`H` (HOP)** inside a table **loops** it (jumps the playhead to its param's row), so a
  looping table runs with no wasted step — the way you build LSDJ-style arps, stutters and
  evolving timbres.
- Tables apply to **FM / TONE / NOISE** (all columns) and **WAVE** (TSP + VOL + HOP). KIT
  (sample) voices don't run tables.

### Echo (ECHO screen)

A tempo-synced delay built into the engine — now FM-capable, not PSG-only. It copies a
source voice and replays it, quieter and delayed, on target voices:

- **MODE** — off / F2 / F2+F3 / T2 / T2+T3 (which voices echo).
- **TAP1 / TAP2** — each tap's delay **in rows**, so it tracks tempo and swing.
- **RD1 / RD2** — how much quieter each tap is.
- **STER** — stereo ping-pong (taps panned L/R).

Echo only sounds on a target voice when your song isn't using it; the moment a note plays
there, the song takes the channel back.

---

## 8. Command reference

A command sits in a PHRASE step's **CMD/PRM** columns (or a TABLE row) and shapes that
note. Edit the letter with **B-hold + ←→** (↑↓ does nothing on a CMD cell); edit the
parameter `xy` with **B-hold + D-pad**. Most take a two-digit hex parameter.

**Pitch & note**

| Cmd | Name | What it does | Voices |
|---|---|---|---|
| `C` | Chord / arp | Loop through note, +x, +y semitones each tick (`C00` off); on a **T1 GROUP=CHORD** instrument it instead sets the T2/T3 chord (§5) | FM + PSG |
| `F` | Finetune | Signed micro-detune (period / F-number units) | PSG + FM |
| `P` | Pitch bend | Continuous bend, signed rate per tick; persists until `P00` | PSG + FM |
| `L` | Slide | Glide (portamento) to this note at a given rate | PSG + FM |
| `J` | Jump (transpose) | On the plays selected by 4-bit mask `x`, transpose by signed `y` (KIT: swaps the pad) | all |

**Level & timbre (FM)**

| Cmd | Name | What it does |
|---|---|---|
| `X` | Volume | Carrier total level 0–15 (accent). On PSG, level comes from VOL instead |
| `U` | Brightness | Modulator total level / brightness offset 0–127 |
| `Q` | Algo / FB | One-shot ALGO(x) + FB(y) override |
| `O` | Pan | x = left on, y = right on (per-channel FM stereo) |
| `M` | Tremolo | Chip-LFO amplitude depth 0–3 (needs the LFO rate non-zero) |
| `V` | Vibrato | Chip-LFO frequency depth 0–7 (needs the LFO rate non-zero) |
| `Y` | LFO depth | Set AMS(x) + FMS(y) for this note |

**Envelope & gate**

| Cmd | Name | What it does | Voices |
|---|---|---|---|
| `E` | Envelope | Re-slope the AHD ramps: x = attack, y = decay | PSG / WAVE |
| `K` | Kill | Cut the note after xy ticks (`K00` = now; also stops samples) | all |
| `D` | Delay | Delay the note-on by xy ticks | all |
| `R` | Retrigger | Re-fire every `y` ticks; `x` = volume drop per re-strike (decays to silence; persists across empty rows until a new note). `x=0` = plain retrigger | all |
| `Z` | Probability | Play with chance xy/256 (`Z00` never, `ZFF` always, `Z80` ≈ 50/50) | all |

**Voice-specific**

| Cmd | Name | What it does | Voices |
|---|---|---|---|
| `N` | Noise | x = mode (0 white / 1 periodic), y = rate 0–3 | NOISE |
| `B` | Wave bank | Select wave 0–F for the channel | WAVE |
| `S` | Sample rate | DAC walk rate 0–3 | KIT |

**Tables, grooves & timing**

| Cmd | Name | What it does |
|---|---|---|
| `A` | Table | Run / restart a macro table (0–31) on this note (a one-shot override) |
| `H` | Hop | PHRASE: end the phrase **immediately** and step the chain (loops/continues per the song; the H row takes no time). TABLE: loop to a row. Runaway-guarded |
| `I` | Iteration | Gate the note by an 8-bit **play-count** mask — vary a phrase across its repeats without cloning |
| `G` | Groove | Switch the active groove (global) |
| `T` | Tempo | Set a flat tempo in BPM (global) |
| `W` | Wait | This row lasts xy frames (per-row override, global) |

### Varying a phrase — the I / J / Z trio

`I`, `J` and `Z` make **one phrase sound different across its repeats**, so you avoid
cloning just to add a fill:

- **`I`** — *whether* the note plays, on a fixed schedule (the 8-bit play-count mask:
  `FF` always, `55`/`AA` alternate plays, `0F`/`F0` the first/last four of eight).
- **`J`** — *what pitch* (or which drum pad) it plays, transposing on a 4-bit schedule.
- **`Z`** — *whether* it plays, by random chance.

`I` and `J` are deterministic and loop with the phrase's play count (a fill lands in the
same place every time); `Z` adds genuine randomness. Combine them and a single 16-step
phrase carries a whole evolving part.

---

## 9. Timing, grooves, transpose

**Grooves are the clock.** A groove is a 16-value list of tick-counts per row (one tick =
one video frame), so an uneven pair like `8,4` shuffles the feel. There are **16 grooves**;
the GROOVE screen edits the current one (move the cursor up onto the number to pick which),
and the `G` command switches groove mid-song.

Tempo *is* the groove. **TMPO** (on PROJECT) shows the BPM of the current groove and steps
through the achievable BPMs, scaling the whole groove together so your swing is kept. The
`T` command sets a flat tempo by BPM; the `W` command stretches a single row.

**TSP** (on PROJECT) transposes the whole song ±semitones — handy for matching a vocalist
or another instrument. It doesn't move sample drums.

---

## 10. Live mode

**PROJECT → MODE: LIVE** turns the SONG screen into a performance launcher (the title
reads **LIVE**). Each track loops its chain independently, and you trigger changes by hand:

- **C + B** on a populated cell **launches** that track from there. It's quantized: stopped
  → starts now; running with that track silent → on the next master 16-row bar; running and
  already playing → at the current chain's end.
- **C + B** on an empty cell (or the track's currently-playing cell) **stops** that track at
  the next boundary.
- **Start** launches every populated track on the cursor row.
- **A-hold + Up/Down** pages the 240-row view.

A launched track shows its own playhead and loops the top of its contiguous chain group on
an empty cell. Switch back to **MODE: SONG** for normal start-to-finish playback.

---

## 11. Saving & loading — the FILES screen

Songs live in the cartridge's battery-backed save RAM (or your emulator's `.sav` file).
Reach FILES with **C-hold + Down** from SONG. Playback stops while you're here.

FILES shows a **packed list** of your saved songs (16 per page, `Pn/m`), each with its
8-character name and stored size in KB, then a trailing **`(EMPTY)`** slot whenever there's
room — up to **32** songs. A small **SRAM / FREE** readout sits under the map.

**Moving and naming**

- **Up / Down** — pick a slot (including the trailing empty one).
- **B-hold + Left / Right** — move the name cursor across the 8 characters.
- **B-hold + Up / Down** — cycle the character under the cursor (blank → A–Z → specials, or
  down → 0–9). On a saved slot this renames it live; the `(EMPTY)` slot starts a fresh name
  on your first keystroke, which becomes the new song's name on SAVE. The name travels
  inside the song.

**The action menu** — **C-hold + B** opens it on the right; **Up/Down** choose and **B**
runs (and closes):

- **SAVE** — write the working song to the selected slot (overwrites an existing one; on the
  empty slot, creates a new file). *Saving only happens when you press SAVE* — edits aren't
  auto-saved, so save often.
- **LOAD** — load the selected song. On the **empty** slot, blanks the working song for a
  fresh start.
- **CLEAR** — delete the slot and close the gap (remaining songs slide down).
- **PURGE PH / PURGE CH** — blank phrases / chains **not reachable** from the SONG, so they
  drop out of the next save. Acts on the **working** song (save afterwards to bank it). Tap
  twice to confirm; the header shows **`FREED nn`**. They never renumber the rest, so nothing
  in your song breaks.

A refused save (directory or SRAM full) shows **FULL** by the FREE meter; a fresh cart is
formatted on first boot; a load that fails its checksum blanks to a known state. On a real
cart with a battery, SAVE persists instantly; in an emulator the `.sav` is usually written
when you quit, so save in genmddj **then** close the emulator normally.

---

## 12. Options

Settings that belong to the **machine**, not the song (they persist in SRAM):

- **VID** — video region: **AUTO** (default, auto-detect at boot), **PAL**, or **NTSC**.
  Affects tuning and tempo math.
- **SYNC** — clock sync mode (§13).
- **PALETTE** — UI colour scheme.
- **CLONE** — **SLIM** or **DEEP**, how a SONG chain clones (§4).
- **AUDITION** — note-entry prelisten on PHRASE/INSTR, **ON** by default (§2).

---

## 13. Syncing to other gear

genmddj can lock its tempo to another machine over **controller port 2**, using the same
2-bit wire protocol as SMSGGDJ — so it can cross-sync with another genmddj, an SMSGGDJ /
GGDJ, or analog-clock gear. Set it on **OPTIONS → SYNC**:

- **OFF** — no sync (default).
- **OUT** — this unit is the **master**; it sends one clock per row while playing. A unit set
  to **IN** locks to it at any tempo. (Hardware-tested two-MD OUT→IN.)
- **PULSE** — a simple analog pulse for Volca / Pocket Operator gear.
- **IN** — **follow** an OUT master (one row per clock). Press **Start** (or **B+Start**) and
  it waits — the top bar shows **WAIT** — until the clock starts, then locks on. While
  following, the master drives the timing (your groove and `W` are ignored, restored when you
  leave IN).
- **IN24** — follow a **24-PPQN** source (e.g. the **smsggdj-link-esp32** Ableton Link
  bridge); same WAIT-then-lock behaviour.

Cross-sync uses the identical wire protocol both ways: genmddj `OUT` ↔ SMSGGDJ `IN`, and
either unit's `IN24` follows the Link bridge.

---

## 14. Quick reference

```
MOVE          D-pad
INSERT/EDIT   B tap  /  B hold + D-pad   (L/R small, U/D big)
AUDITION      B tap on a note (PHRASE, stopped) or INSTR
PASTE         B double-tap
COPY          B hold + A tap
MINT/CLONE    B double-tap on a SONG chain# / CHAIN phrase#
BLOCK SELECT  A hold + B tap  → D-pad extend, B copy, A cut, C cancel
CHANNEL       A hold + Left/Right        (CHAIN / PHRASE)
FLIP/PAGE     A hold + Up/Down           (phrase / chain / SONG page)
SCREENS       C hold + D-pad
PLAY FROM HERE  C + B                    (solo the current screen)
PLAY SONG     Start                      (LIVE: launch cursor row)
SYNC WAIT     B + Start                  (when SYNC = IN / IN24)
```

```
SCREEN MAP
   OPTIONS  PROJECT                   WAVE
   SONG     CHAIN    PHRASE   INSTR    TABLE
   FILES    GROOVE            FM LFO   ECHO

VOICES   F1 F2 F3 F4 F5 F6   (FM; F6 also hosts samples/wavetables)
         T1 T2 T3            (PSG square)
         NO                  (PSG noise / drums)
```

## 15. The companion tools (`user-tools/`)

A suite of **browser tools** (just open the `.html` — no install) for getting music and
sounds into genmddj and customising the ROM. They move data between a handful of file types:

```
FILE TYPES
  .bin       a genmddj ROM (what you flash / emulate)
  .gmdj      one song (this suite's song container)
  .srm/.sav  a cartridge save (config + instrument bank + up to 32 songs)
  .gmi       one instrument (a YM2612 patch)        .genkit  one sample drum kit
  .wav  a sample   .vgm  a game chip-log   .als/.mid/MML  music sources   .adv  an Ableton Operator patch
```

```
CUSTOMISE THE ROM      (drop a .bin, edit, export a re-checksummed .bin)

   .gmi .tfi .vgi .adv .vgm ──► instrument patcher ─┐
   .wav .genkit ─────────────► kit patcher ─────────┤
                                palette patcher ─────┼──►  patched .bin ──►  flashcart / emulator
                                font patcher ────────┤
   .gmdj  (or .bin defaults) ─► wave editor ─────────┘


MAKE & MANAGE SONGS / SAVES

   .als .mid / MML ──► als2genmddj ──► .gmdj ──┐
                                               ├──► save tool ──► .srm/.sav ──► flashcart / emulator
   .gmi ──► bank editor ──► instrument bank ───┘        │
                                                        └─ de-re-interleaver:  EverDrive 64K ⇄ 32K logical
```

Each tool — what it does · **in** → **out**:

- **palette patcher** — recolour the 8 UI palettes (picks snap to legal Sega colours).
  **a `.bin`** → a patched **`.bin`**.
- **font patcher** — redraw the 8×8 UI font (96 glyphs + an auto-derived inverse set; system-font
  import). **a `.bin`** (or a system font) → a patched **`.bin`**, or **`font.bin`** for a build bake.
- **instrument patcher** — edit, **audition** (a register-level OPN2 piano), convert, and rip the 32
  FM patches. **a `.bin`, or `.gmi`/`.tfi`/`.vgi`/`.adv`, or a `.vgm`/`.vgz` game log** → a patched
  **`.bin`**, or **`.gmi`/`.tfi`/`.vgi`/`.adv`**.
- **kit / sample patcher** — build sample drum kits (per-pad trim / gain / tanh / fade; drag `.wav`s
  onto pads). **a `.bin`, `.wav` files, or a `.genkit`** → a patched **`.bin`**, a **`.genkit`**, or **`.wav`**.
- **wave editor** — draw the 16 wavetables (canvas, presets, or an `f(x)=` expression). **a `.bin`**
  (the factory defaults every NEW song uses) **or a `.gmdj`** (one song's waves) → the same, edited.
- **save tool** — extract songs from a cart save, edit config (palette / video / sync), keep the
  instrument bank, and build a fresh save. **a `.srm`/`.sav` and/or `.gmdj` songs** → a 32 KB (1-song)
  or 64 KB (3-song) **`.srm`/`.sav`**, plus extracted **`.gmdj`** songs.
- **bank editor** — manage the 32-slot SRAM instrument library (shared across songs). **a `.srm`/`.sav`
  + `.gmi` per slot** → the save with its bank rewritten (songs/config untouched).
- **de-re-interleaver** — convert a save between EverDrive's 64 KB odd-byte layout and the 32 KB
  logical layout. **a `.srm`** → the converted **`.srm`**.
- **als2genmddj** — get music in and out: Ableton **`.als`** & MIDI **`.mid`** ⇄ **`.gmdj`**, **MML
  text** ⇄ **`.gmdj`**, and one Ableton Operator **`.adv`** ⇄ a **`.gmi`** instrument. Includes a song viewer.
- **build-time bakers** (run by `make`, not in the browser) — the factory instruments, samples, note
  tables, font, and default palettes/waves are baked from source; edit the source files and rebuild.

Full detail (formats, the conversion maths, the marker-locator scheme) is in
[`user-tools/README.md`](user-tools/README.md), `PRESETS.md`, `PALETTE.md`, and `ALS.md`.

Have fun. Save often.
