# user-tools

The **user-facing companion suite** — what a *musician* runs, distinct from the ROM **build
toolchain** in `tools/` (which `make` invokes: `maketables.py`, `makesamples.py`, `makefont.py`,
`makeinstruments.py`, `makealgos.py`, `makewaves.py`, `fixheader.py`).

Nothing here is required to build the ROM. There are **three ways data reaches a running genmddj**,
and the tools split along them:

| Path | When | Needs | Examples |
|---|---|---|---|
| **Baked** | build time (pre-compile) | the toolchain (Python + vasm) | factory instruments (`fm_factory`), note tables, font, samples, default palettes (`pal_table`) |
| **Patched** | post-build, on a finished `.bin`/`.srm` | just the browser tool | the palette + instrument patchers, `kitpatch` |
| **Runtime-loaded** | while the ROM runs | nothing — read from SRAM | the song, the SRAM user instrument library, config |

The handoff is always a **documented format**, never a code dependency:
- **instrument record** — the 64-byte FM patch, i.e. a `.gmi` file (`PRESETS.md`). Baked into the
  ROM factory bank (32 records behind the `GMINSTR0` locator) from `instrument-patches/*.gmi`,
  patched in place by the browser **instrument patcher**, or loaded per-slot into the SRAM user
  library.
- **save / `.gmdj` / `.srm`** — the song + config format, read/written on cart SRAM.

## At a glance — the data flow

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

The table below is the per-tool detail; the same map (with a what/in→out bullet per tool) is in
[`../MANUAL.md`](../MANUAL.md) §15.

## What ships now

| Tool | File | Kind | Edits |
|---|---|---|---|
| **palette patcher** | `genmddj-palette-patcher.html` | ROM-patcher | 8 UI palettes (`GMDJPAL0`); swatch pick snaps to the nearest Sega colour |
| **instrument patcher** | `genmddj-instrument-patcher.html` | patcher + converter + ripper | 32 FM patches (name, algo/fb, 4 operators) with a piano **audition** (register-level OPN2 core); **standalone** (no ROM) or patches `GMINSTR0` in a `.bin`; imports/exports `.gmi` (native), `.tfi`/`.vgi`, **Ableton Operator `.adv`**; **rips patches from a `.vgm`/`.vgz` game log** (Import VGM — key-on register snapshots, deduped + ranked by play count) |
| **kit/sample patcher** | `genmddj-kit-patcher.html` | ROM-patcher + `.genkit` tool | sample kits, per-pad trim / gain / tanh / fade; drop `.wav`s onto pads; **import/export a single kit as a `.genkit`** (the kit's source audio + per-pad edits, re-editable, no ROM needed) |
| **de-re-interleaver** | `de-re-interleaver.html` | `.srm` tool | EverDrive 64 KB odd-byte ⇄ 32 KB logical save |
| **save tool** | `genmddj-savetool.html` | `.srm`/`.sav` tool | extract `.gmdj` songs from a cart save (checksum-validated), edit config (palette/video/sync), preserve the SRAM instrument bank, **build** a new 32 KB (1 song) or 64 KB (3 song) save; song/chains/phrases/instruments **viewer** |
| **als ↔ genmddj** | `als2genmddj.html` | converter | Ableton `.als` **& Standard MIDI `.mid`** → `.gmdj` (and `.gmdj`→`.als`): 9 channels → F1–F6 (FM) + S1–S3 (TONE); clips → phrases → chains (contiguous runs fill chains, empty scene = new chain); 16th-grid quantise, octave-fold, highest-pitch-wins, optional velocity→`X`; **converts FM tracks' Ableton Operator devices ⇄ YM2612 patches** (+ `.gmi`); also **MML text ⇄ `.gmdj`** — one line per channel (`F1`–`F6`/`S1`–`S3`), classic `cdefgab`+`#`/`-` · `o`/`<`/`>` · `l`/dotted/`&` · `r` · `@`inst · `v`→`X` · `;`comment (`t` is an annotation, tempo = grooves); song **viewer** |
| **wave editor** | `genmddj-wave-editor.html` | ROM-patcher + `.gmdj` tool | edit the **16 wavetables** (32 steps, 8-bit `$80`-centre) — canvas draw, presets, smooth/invert, and an **expression field** (`f(x)=sin(x)+sin(3*x)/3`, audio-domain −1…1, `sin cos saw tri sq pulse noise` over phase `x`). Drop a **`.bin`** to edit the factory defaults (`GMDJWAV0` — what every NEW song is seeded with, re-checksumed) **or** a **`.gmdj`** to edit one song's waves |
| **font patcher** | `genmddj-font-patcher.html` | ROM-patcher + baker | edit the **8×8 UI font** (96 glyphs + auto-derived inverse) — pixel editor, system-font import, presets, locked UI symbols; **ROM-patches `GMDJFON0`** in a `.bin`, or saves `font.bin` for a build-time bake (`tools/font_custom.bin` + `make`) |
| **bank editor** | `genmddj-bank-editor.html` | `.sav`/`.srm` tool | edit the **32-slot SRAM instrument bank** (the cross-song library) — load/save `.gmi` per slot, clear, bulk-fill; edits in place (config + songs untouched) |
| **factory-bank baker** | `../tools/makeinstruments.py` | baker (build-time) | bakes `instrument-patches/*.gmi` → the 32-record ROM factory bank (`GMINSTR0`); run by `make` |

The palette + kit patchers (and the ROM side of the instrument patcher) share one shape: drop a `.bin`,
locate data by an **embedded marker**, edit, **re-checksum** the MD header on export — a shared core
(binary I/O, marker-find, checksum) worth factoring out. The **instrument patcher** has outgrown that
mould: it also runs **standalone** (an in-memory bank seeded from the factory patches, so you can convert
patches with no ROM in sight) and is a two-way **patch converter** — `.gmi` (native, lossless), `.tfi`/`.vgi`
(other YM2612 tools), and **Ableton Operator `.adv`** (a 4-op FM synth → YM2612 via the algorithm map +
envelope-time→chip-rate curve, and back out as a valid Operator preset).

## Planned

| Dir | Tool | Emits | Spec |
|---|---|---|---|
| `extract/` | game-patch extractors — **SMPS**, **GEMS** (native re-packs). **VGM already ships** in the instrument patcher's Import VGM | `.gmi` | `PRESETS.md` §5 |

## Baker vs patcher — and why instruments have both

The **patcher** edits one finished ROM in the browser: no toolchain, no rebuild — ideal for a musician
retuning the factory voices on a `.bin` they already have. The **baker** (`makeinstruments.py`) is the
build-time keystone: `make` bakes the factory bank from the `.gmi` files in `instrument-patches/`, so
the bank is **data-driven** — edit a `.gmi`, rebuild. Both speak the same `.gmi` instrument record, so a
patch round-trips between them.

So they're complementary, exactly like palettes — a **baked default** (`fm_factory` / `pal_table`, in
source and reproducible) plus a **patcher** for in-place tweaks:

```
baked:    instrument-patches/*.gmi ─▶ makeinstruments.py ─▶ fm_factory (GMINSTR0, in ROM)   [versioned, needs toolchain]
patched:  finished .bin            ─▶ instrument patcher ─▶ re-checksummed .bin             [one ROM, no rebuild]
runtime:  .gmdj / .srm             ─▶ load ─▶ SRAM user library                             [add voices to songs, no rebuild]
```

The factory voices live as the `.gmi` files in `instrument-patches/` (filename order sets the slot,
the filename sets the name) — that's the source of truth; `make` bakes them, and the on-console **NEW**
seeds a fresh song from the baked bank.

**Many front-ends, one record.** The instrument patcher, its VGM ripper, and the Ableton `.adv` adapter
all converge on the **`.gmi`** instrument record (and the planned SMPS/GEMS extractors will too). The
split that matters: the game rips are **native re-packs** (the patches already *are* YM2612 operator
registers); the Ableton adapter **adapts** a different FM engine (Operator), so it carries the
calibration in `ALS.md`. VGM is the only route for custom-driver titles (e.g. Streets of Rage).
