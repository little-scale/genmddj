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
| **instrument patcher** | `genmddj-instrument-patcher.html` | ROM-patcher | the 32 factory FM patches (`GMINSTR0`): name, algo/fb/pan, the 4 operators |
| **kit/sample patcher** | `kit/kitpatch.html` | ROM-patcher | sample kits, per-pad fade/gain (`DESIGN.md` §10.3) |
| **de-re-interleaver** | `de-re-interleaver.html` | `.srm` tool | EverDrive 64 KB odd-byte ⇄ 32 KB logical save |
| **factory-bank author** | `../tools/gen_factory_bank.py` | baker (one-shot) | emits the inline `fm_factory` block — the canonical 32 patches |

All three patchers share one shape: drop a `.bin`, locate data by an **embedded marker**, edit,
**re-checksum** the MD header on export. That shared core (binary I/O, marker-find, checksum) is worth
factoring out now that three of them exist.

## Planned

| Dir | Tool | Emits | Spec |
|---|---|---|---|
| `instrument/` | browser FM editor (Web Audio + JS/WASM YM2612 — **audition** patches) | instrument CSV | `PRESETS.md` §4 |
| `font/`     | UI font patcher — edit/import the 8×8 glyph tiles | patched `.bin` | `PALETTE.md` §7 |
| `extract/`  | game-patch extractors — **SMPS**, **GEMS**, **VGM** (native re-packs) | instrument CSV | `PRESETS.md` §5 |
| `ableton/`  | **`.adv`** (one Operator → instrument) + **`.als`** (song + FM adaptation) | instrument CSV / song | `ALS.md` |
| `savetool/` | list/export/import/build `.srm`/`.gmdj`; config read/write | `.gmdj` / `.srm` | `SAVEFORMAT.md` |

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
