# user-tools

The **user-facing companion suite** — what a *musician* runs, distinct from the ROM **build
toolchain** in `tools/` (which `make` invokes: `maketables.py`, `makesamples.py`, `makefont.py`,
`makealgos.py`, `fixheader.py`).

Nothing here is required to build the ROM. There are **three ways data reaches a running genmddj**,
and the tools split along them:

| Path | When | Needs | Examples |
|---|---|---|---|
| **Baked** | build time (pre-compile) | the toolchain (Python + vasm) | factory instruments (`fm_factory`), note tables, font, samples, default palettes (`pal_table`) |
| **Patched** | post-build, on a finished `.bin`/`.srm` | just the browser tool | the palette + instrument patchers, `kitpatch` |
| **Runtime-loaded** | while the ROM runs | nothing — read from SRAM | the song, the SRAM user instrument library, config |

The handoff is always a **documented format**, never a code dependency:
- **instrument record** — the 64-byte FM patch (`DESIGN.md` §6). Baked into the ROM factory bank
  (32 records behind the `GMINSTR0` locator) or loaded into the SRAM user library. The browser
  **instrument patcher** edits the baked bank in place; the planned CSV path (below) authors it.
- **save / `.gmdj` / `.srm`** — `SAVEFORMAT.md`. Songs and config, read/written on cart SRAM.

## What ships now

| Tool | File | Kind | Edits |
|---|---|---|---|
| **palette patcher** | `genmddj-palette-patcher.html` | ROM-patcher | 8 UI palettes (`GMDJPAL0`); swatch pick snaps to the nearest Sega colour |
| **instrument patcher** | `genmddj-instrument-patcher.html` | patcher + converter + ripper | 32 FM patches (name, algo/fb, 4 operators) with a piano **audition** (register-level OPN2 core); **standalone** (no ROM) or patches `GMINSTR0` in a `.bin`; imports/exports `.gmi` (native), `.tfi`/`.vgi`, **Ableton Operator `.adv`**; **rips patches from a `.vgm`/`.vgz` game log** (Import VGM — key-on register snapshots, deduped + ranked by play count) |
| **kit/sample patcher** | `kit/kitpatch.html` | ROM-patcher | sample kits, per-pad fade/gain (`DESIGN.md` §10.3) |
| **de-re-interleaver** | `de-re-interleaver.html` | `.srm` tool | EverDrive 64 KB odd-byte ⇄ 32 KB logical save |
| **save tool** | `genmddj-savetool.html` | `.srm`/`.sav` tool | extract `.gmdj` songs from a cart save (checksum-validated), edit config (palette/video/sync), preserve the SRAM instrument bank, **build** a new 32 KB (1 song) or 64 KB (3 song) save; song/chains/phrases/instruments **viewer** |
| **als ↔ genmddj** | `als2genmddj.html` | converter | Ableton `.als` **& Standard MIDI `.mid`** → `.gmdj` (and `.gmdj`→`.als`): 9 channels → F1–F6 (FM) + S1–S3 (TONE); clips → phrases → chains (contiguous runs fill chains, empty scene = new chain); 16th-grid quantise, octave-fold, highest-pitch-wins, optional velocity→`X`; **converts FM tracks' Ableton Operator devices ⇄ YM2612 patches** (+ `.gmi`); song **viewer** |
| **wave editor** | `genmddj-wave-editor.html` | ROM-patcher + `.gmdj` tool | edit the **16 wavetables** (32 steps, 8-bit `$80`-centre) — canvas draw, presets, smooth/invert, and an **expression field** (`f(x)=sin(x)+sin(3*x)/3`, audio-domain −1…1, `sin cos saw tri sq pulse noise` over phase `x`). Drop a **`.bin`** to edit the factory defaults (`GMDJWAV0` — what every NEW song is seeded with, re-checksumed) **or** a **`.gmdj`** to edit one song's waves |
| **font patcher** | `genmddj-font-patcher.html` | ROM-patcher + baker | edit the **8×8 UI font** (96 glyphs + auto-derived inverse) — pixel editor, system-font import, presets, locked UI symbols; **ROM-patches `GMDJFON0`** in a `.bin`, or saves `font.bin` for a build-time bake (`tools/font_custom.bin` + `make`) |
| **bank editor** | `genmddj-bank-editor.html` | `.sav`/`.srm` tool | edit the **32-slot SRAM instrument bank** (the cross-song library) — load/save `.gmi` per slot, clear, bulk-fill; edits in place (config + songs untouched) |
| **factory-bank author** | `../tools/gen_factory_bank.py` | baker (one-shot) | emits the inline `fm_factory` block — the canonical 32 patches |

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
| `instrument/` | the **CSV** authoring path for the baker (the instrument patcher already audits + edits patches) | instrument CSV | `PRESETS.md` §4 |
| (als2genmddj) | **MML** text input — a third intake format alongside `.als`/`.mid` (classic MML: `cdefgab`, `o`/`<`/`>`, `l`, `t`, `r`, `&`, `v`→`X`) → `.gmdj` | `.gmdj` | — |
| `extract/`  | game-patch extractors — **SMPS**, **GEMS** (native re-packs; **VGM now ships** in the instrument patcher's Import VGM) | instrument CSV | `PRESETS.md` §5 |

## Baker vs patcher — and why instruments have both

The **patcher** edits one finished ROM in the browser: no toolchain, no rebuild — ideal for a musician
retuning the factory voices on a `.bin` they already have. The **baker** (`makeinstruments.py`,
planned) is the keystone: it makes the factory bank **data-driven** from an **instrument CSV**, and
that CSV is the shared schema the extractors (SMPS/GEMS/VGM) and the Ableton adapters all converge on.

So they're complementary, exactly like palettes — a **baked default** (`fm_factory` / `pal_table`, in
source and reproducible) plus a **patcher** for in-place tweaks:

```
baked:    instrument CSV ──▶ tools/baker ──▶ fm_factory (in ROM)   [canonical, versioned, needs toolchain]
patched:  finished .bin  ──▶ instrument patcher ──▶ re-checksummed .bin   [one ROM, no rebuild]
runtime:  .gmdj / .srm   ──▶ load ──▶ SRAM user library            [add voices to songs, no rebuild/patch]
```

`tools/gen_factory_bank.py` is the **seed of the baker** — hardcoded patches today, emitting the inline
`fm_factory` block. The planned step is to drive it from a CSV that the FM editor and the extractors
emit, so the bank stops being hand-authored. Until then the **live source of truth** for the factory
voices is `fm_factory` in `src/main.asm` plus whatever the instrument patcher writes into a `.bin`.

**Five front-ends, one schema.** The CSV editor + the three extractors + the two Ableton adapters all
converge on the **instrument CSV**. The split that matters: the game extractors are **native re-packs**
(the patches already *are* YM2612 operator registers); the Ableton adapters **adapt** a different FM
engine (Operator), so they carry the calibration in `ALS.md`. VGM is the only route for custom-driver
titles (e.g. Streets of Rage).
