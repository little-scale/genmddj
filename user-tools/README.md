# user-tools

The **user-facing companion suite** — what a *musician* runs, distinct from the ROM **build
toolchain** in `tools/` (which `make` invokes: `maketables.py`, `makesamples.py`, `makefont.py`,
`makealgos.py`, `fixheader.py`, and the instrument **baker** `makeinstruments.py`).

Nothing here is required to build the ROM. These tools **produce inputs** that feed the build or
load at runtime, and the handoff is always a **documented format**, never a code dependency:

- **instrument CSV** — `PRESETS.md` (the FM instrument record). Consumed by `tools/makeinstruments.py`
  into the ROM factory bank, or loaded into the SRAM user library.
- **save / `.gmdj` / `.srm`** — `SAVEFORMAT.md`. Songs and config, read/written on cart SRAM.

```
data flow:   user-tools  ──CSV / .gmdj──▶  tools/baker  ──▶  ROM
                  │                                      └──runtime load──▶  SRAM
```

## Planned layout

| Dir | Tool | Emits | Spec |
|---|---|---|---|
| `editor/`   | browser FM editor (Web Audio + JS/WASM YM2612 — audition patches) | instrument CSV | `PRESETS.md` §4 |
| `extract/`  | game patch extractors — **SMPS**, **GEMS**, **VGM** (native re-packs) | instrument CSV | `PRESETS.md` §5 |
| `ableton/`  | **`.adv`** (one Operator → instrument) + **`.als`** (song + FM adaptation) | instrument CSV / song | `ALS.md` |
| `savetool/` | list/export/import/build `.srm`/`.gmdj`; config read/write | `.gmdj` / `.srm` | `SAVEFORMAT.md` §"tools/savetool" |

**Five front-ends, one schema.** The editor + the three extractors + the two Ableton adapters all
converge on the **instrument CSV**. The split that matters: the game extractors are **native
re-packs** (the patches already *are* YM2612 operator registers); the Ableton adapters **adapt** a
different FM engine (Operator), so they carry the calibration in `ALS.md`. VGM is the only route
for custom-driver titles (e.g. Streets of Rage).

## Build order

`tools/makeinstruments.py` (baker) → `editor/` → `extract/` (SMPS → GEMS → VGM) → `ableton/`
(`.adv` → `.als`). The baker is the keystone (smallest, makes the bank data-driven); the rest
target the CSV the baker already eats.

*This dir is scaffolding for now — the suite isn't built yet. It records where each tool lands so
the first one (the `.adv` converter or the baker's CSV side) starts in the right place.*
