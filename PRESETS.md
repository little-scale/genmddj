# genmddj instrument presets + tooling

**Plan doc — 2026-06-21.** A factory bank of FM instrument presets baked in ROM, plus a
browser editor for them and an extractor that pulls patches out of real Sega games. Companion
to the three-tier instrument model — the factory tier is exactly this bank.

## 1. The factory preset bank

The instrument model is three tiers: **factory (ROM)** → user library (SRAM) →
per-song pool. This is the factory tier made real: **32 FM presets baked in ROM**, browseable
on-console, `LOAD`-copied into a song's instrument pool. 32 × 64 B = 2 KB — trivial in a 2 MB
ROM, and it matches `NINSTR=32` so a bank can fully populate a song. Each preset carries an
8-char name. Expandable later (ROM is cheap); 32 is the curated baseline.

The bank becomes **data-driven**: a CSV is the source of truth, a build step bakes it into ROM
(today the factory instruments are hand-written asm). That CSV is the spine all three tools share.

## 2. The shared spine — one CSV schema

A YM2612 patch is just operator registers, and genmddj's instrument record already *is* that.
So **one CSV schema = the FM instrument record**, and it is the common destination of **five
front-ends** — the browser editor, the three game extractors (SMPS / GEMS / VGM, §5), and the two
Ableton adapters (`.adv` / `.als`, see `ALS.md`) — and the single input of the baker. Define it
once; everything plugs in. The split that matters: game sources are **native re-packs**; Ableton
sources are **adaptations** of a different FM engine.

### 2.1 CSV columns (FM preset — `i_type = 0`)

One row per preset. Values decimal unless noted. Ranges are validated by the baker.

| Column | Range | Record | Meaning |
|---|---|---|---|
| `name` | ≤8 ASCII | (sidecar) | display name |
| `algo` | 0–7 | `i_algo` | FM algorithm |
| `fb` | 0–7 | `i_fb` | feedback (op1 self-mod) |
| `pan` | 0–3 | `i_pan` | 0 off / 1 R / 2 L / 3 L+R — **forced to 3 when loaded from the ROM factory bank** (rom_load_instr + the NEW dump); SRAM/song loads keep the stored value |
| `ams` | 0–3 | `i_ams` | LFO amplitude-mod sensitivity |
| `fms` | 0–7 | `i_fms` | LFO freq-mod (vibrato) sensitivity |
| `hld` | 0–15 | `i_hld` | gate ticks×2; 15 = hold |
| `vol` | 0–15 | `i_vol` | carrier attenuation; 15 = full |
| `op{1..4}_mul` | 0–15 | op+0 | multiple |
| `op{1..4}_dt`  | 0–7  | op+1 | detune (4–7 = negative) |
| `op{1..4}_tl`  | 0–127| op+2 | total level (0 = loudest) |
| `op{1..4}_rs`  | 0–3  | op+3 | rate scaling |
| `op{1..4}_ar`  | 0–31 | op+4 | attack rate |
| `op{1..4}_am`  | 0–1  | op+5 | amplitude-mod enable |
| `op{1..4}_d1r` | 0–31 | op+6 | first decay rate |
| `op{1..4}_d2r` | 0–31 | op+7 | second decay (sustain) rate |
| `op{1..4}_rr`  | 0–15 | op+8 | release rate |
| `op{1..4}_sl`  | 0–15 | op+9 | sustain level |
| `tbl` | 0–31 / 255 | `i_tbl` | macro table (255 = none) — default 255 |
| `tbs` | 0–255 | `i_tbs` | table speed — default 0 |
| `tsp` | −128…127 | `i_tsp` | transpose, signed semitones — default 0 |

`= 8 header + 40 operator + 3 tail = 51 columns + name`. Record bytes 50–52 (`i_kit/i_gain/
i_rate`) and 54–63 are KIT-union / reserved — **not** written for an FM preset (baker zero-fills).

### 2.2 Operator order — the one gotcha ⚠

Columns use **logical operator order op1–op4 = YM2612 operators 1,2,3,4** (datasheet
convention — same as VGM, most FM editors, and the operator the modulation routing refers to).
But the **register offsets don't match**: `$30/$34/$38/$3C` address operators **1,3,2,4**. So:

- genmddj's record stores operators in **register order** (slot 0–3 = ops **1,3,2,4**).
- SMPS voices pack operators in the **same register order** (bytes written to `$30,$34,$38,$3C`).

So the baker maps logical `op1,op2,op3,op4` → storage slots `0,2,1,3`; the SMPS extractor maps
its 4 byte-groups (register order) → logical `1,3,2,4`. A one-line permutation in each tool —
but **the #1 source of silent-wrong-patch bugs**. Validate against a known voice (e.g. a Sonic
bass) by ear before trusting a batch. (Keeping the CSV logical is deliberate: it's the universal
interchange order, so VGM and any future format line up without a special case.)

## 3. Tool 1 — the baker (`tools/makeinstruments.py`)

CSV → a binary include assembled into the ROM, exactly like `maketables.py` / `makesamples.py`
/ `makefont.py` already do. Smallest tool, build it **first** — it makes the bank data-driven and
lets you hand-author a CSV and bake it before anything else exists.

- Reads the CSV, validates ranges, applies the op-order permutation, packs each row into a
  64-byte record (zero-filling the non-FM tail), emits `build/instruments.bin` + a names blob.
- `Makefile` rule + an `incbin` in `src/main.asm`; the boot copy into `instrum` ($FFB000) sources
  it. `fixheader.py` re-checksums as usual.
- Round-trips: `dump` (ROM/record → CSV) so a hand-tweaked bank can be re-exported.

## 4. Tool 2 — the browser editor

Edit the bank visually, with the on-console FM screen's algorithm diagram + envelopes but
interactive. **The killer feature is audition**: Web Audio + a JS/WASM YM2612 core (rippable
from MD emulators) so you *hear* each patch as you drag. CSV in/out (§2). This tool also
exercises and pins the schema, so it comes before the extractor. Optional: an on-console-accurate
preview (same F-number tables) so what you hear in the browser matches the hardware.

## 5. Tool 3 — the extractor (three game front-ends)

Pulls FM patches out of real games. Three sources, all producing **YM2612-native** patches — a
**re-pack, no fidelity loss** (unlike the Ableton path in `ALS.md`, which must *adapt* a different
FM engine):

- **SMPS** — Sega first-party (Sonic + much of the catalogue); named, ordered voice banks.
- **GEMS** — US/Western third-party; GEMS instrument banks.
- **VGM** — driver-agnostic; the net for **custom drivers** (e.g. Streets of Rage — Koshiro's own
  driver, which neither parser can read) and anything else with a register log.

Order: **SMPS first** (best-documented, validates the unpack + the §2.2 op permutation against
iconic voices), then **GEMS** and **VGM**. All emit the §2 CSV; together with `ALS.md`'s `.adv`/
`.als` adapters, that's **five front-ends converging on one instrument schema**.

### 5.1 SMPS extraction

SMPS is Sega's standard driver (Sonic + a huge swath of first-party titles) and its voice format
is thoroughly reverse-engineered. A voice is **25 bytes**, packed as the raw register values:

```
byte  0      $B0  (FB<<3)|ALGO          -> fb, algo
bytes 1–4    $30  (DT<<4)|MUL  ×4 ops   -> dt, mul      (register order: S1,S3,S2,S4)
bytes 5–8    $40  TL          ×4        -> tl
bytes 9–12   $50  (RS<<6)|AR  ×4        -> rs, ar
bytes 13–16  $60  (AM<<7)|D1R ×4        -> am, d1r
bytes 17–20  $70  D2R         ×4        -> d2r
bytes 21–24  $80  (SL<<4)|RR  ×4        -> sl, rr
```

Conversion is a **re-pack, not a reinterpretation** — same chip params, just unpacked into the
§2 columns (with the §2.2 op permutation). The work is *locating the voice bank*: detect the SMPS
variant by signature and follow its voice-pointer table. Start with the Sonic-family SMPS
(Sonic 1/2/3&K) — best-documented, highest hit-rate — then widen. A per-game offset table keyed
by ROM hash is the reliable fallback for stubborn titles. Auto-name `Game_vNN`; rename in the editor.

*Caveats:* SMPS TL is occasionally stored with a flag bit or offset in some variants — clamp to
0–127 and validate; some banks pad to 26+ bytes; voice count is in the bank header or implied by
the pointer table.

### 5.2 GEMS extraction (US/Western third-party)

GEMS ("Genesis Editor for Music and Sound," Recreational Brainware) was the common driver/toolkit
for many US-developed Genesis titles. Like SMPS, its FM instruments are **YM2612-native** operator
params (algorithm, feedback, per-op DT/MUL/TL/RS/AR/D1R/D2R/RR/SL), so the conversion is again a
**re-pack**, just from a different container. GEMS keeps instruments in an instrument bank with its
own record layout and an instrument *type* (FM / PSG / sampled / multi) — locate the bank via the
GEMS engine's known structure and parse the FM records per the documented GEMS format.

*Caveats:* skip/flag non-FM and multi instruments; the exact record layout is sourced from the
GEMS format docs (as SMPS's 25-byte layout came from the Sonic scene). Same §2 destination, same
§2.2 operator-order care.

### 5.3 VGM extraction (the driver-agnostic net)

A VGM is a log of the actual chip register writes, so it works for **any** game regardless of its
driver (SMPS/GEMS/custom). Walk the log; at each ch6/ch-N **key-on** (`$28` with key bits),
snapshot that channel's current `$30–$B0` register set → one patch; **dedupe** identical
snapshots. vgmrips has thousands of MD logs, and ROM→emulator→VGM feeds it a cartridge that has
no SMPS bank to parse. Same §2 output. (Per-op `$30–$80` are already in datasheet/logical terms
in the register file, so the permutation handling is the mirror of §2.2.)

This is the broadest net but it loses the game's *named, ordered* bank structure that SMPS/GEMS
give — hence the parsers first for clean named banks, VGM for everything else. It's the **only**
route for custom-driver titles like the **Streets of Rage** series: those patches are already
YM2612-native, so a VGM snapshot → instrument is a direct re-pack with no adaptation, but their
percussion is PCM (→ genmddj's kit/DAC, extracted separately) and Koshiro's slides/vibrato live
in the register *stream* as performance (→ the `P`/`L`/`C`/`F` command layer), not in the patch.

## 6. Decisions / open questions

- **Import is build-time.** Baking into the *factory* bank means "import a game's presets" ends in
  a ROM rebuild — fine for a tracker, but be explicit. Alternative for one-off finds: route into
  the **SRAM user library** (runtime load, no rebuild, fewer slots). Could support both.
- **Bank size** — 32 baseline; revisit if extraction yields banks worth keeping wholesale (a
  larger ROM bank, or a "browse big / copy a few" model).
- **Names provenance** — auto-name on extraction, editor renames; 8 chars × 32 = 256 B in ROM.
- **Op-order validation** (§2.2) — settle and test against a known voice before any batch run.
- **Legal/practical** — synth parameters, freely shared in the tracker scene; frame as personal/
  educational sound-design use.

*Build order: baker → editor → extractor (SMPS → VGM). The CSV schema (§2) is the contract they
all target.*
