# genmddj FM factory bank + instrument tooling

A factory bank of FM instruments baked in ROM, a browser editor that audits and rewrites
them, and converters / rippers that bring patches in from Ableton and from real Sega games.
The factory tier of the three-tier instrument model.

## 1. The factory bank

The instrument model is three tiers — **factory (ROM) → user library (SRAM) → per-song
pool** — and the same 64-byte record moves between them with one LOAD / SAVE pair (`MANUAL.md`
§5). The factory tier is **32 records baked in ROM** (32 × 64 B = 2 KB, matching `NINSTR=32`
so a bank can fully populate a song), each with an 8-char name, browseable on-console and
`LOAD`-copied into a song's pool. **NEW** seeds a fresh song from it.

**It's data-driven and built at build time.** `tools/makeinstruments.py` reads
`instrument-patches/*.gmi` in **filename order** (the `NN ` index prefix sets the order; the
name comes from the filename), packs them into `build/fm_factory.bin`, and `src/main.asm`
`incbin`s that behind the **`GMINSTR0`** locator. Unused slots are padded with a plain sine.
So editing the bank = editing the `.gmi` files (or patching `GMINSTR0` in a built `.bin`
with the browser tool, §3) and rebuilding — there is no hand-written asm block any more.

## 2. The interchange format — `.gmi`

A YM2612 patch *is* operator registers, and genmddj's instrument record already is that, so
the **`.gmi` file is the genmddj 64-byte instrument record** with an `GMDJINS1` magic — the
native, lossless interchange format every FM tool reads and writes. (The earlier plan to use
a CSV as the spine was dropped: the binary record is simpler and the tools all speak it
directly.)

### 2.1 Record fields (FM, `i_type = 0`)

The header (`+$00..+$07`) plus four 10-byte operator groups (`+$08..+$2F`) plus the table /
transpose tail. Decimal ranges:

| Field | Range | Offset | Meaning |
|---|---|---|---|
| `type` | 0 | `+$00` | 0 = FM |
| `algo` | 0–7 | `+$01` | FM algorithm |
| `fb` | 0–7 | `+$02` | feedback (op1 self-mod) |
| `pan` | 0–3 | `+$03` | 0 off / 1 R / 2 L / 3 L+R — **forced to 3 when loaded from the ROM factory bank**; SRAM/song loads keep the stored value |
| `ams` | 0–3 | `+$04` | LFO amplitude-mod sensitivity |
| `fms` | 0–7 | `+$05` | LFO freq-mod (vibrato) sensitivity |
| `hld` | 0–15 | `+$06` | gate ticks×2; 15 = hold until next note |
| `vol` | 0–15 | `+$07` | carrier level; 15 = full |
| **per op ×4** | | `+$08 + 10·slot` | mul, dt, tl(0–127), rs, ar(0–31), am, d1r(0–31), d2r(0–31), rr(0–15), sl(0–15) |
| `tbl` | 0–31 / 255 | `+$30` | macro table (255 = none) |
| `tbs` | 0–255 | `+$31` | table speed (0 = per note) |
| `tsp` | −128…127 | `+$35` | signed-semitone transpose |
| `name` | 8 ASCII | `+$36` | 8-char patch name (`+$36..$3D`; display metadata, not read by the engine) |
| `psweep` | 0–255 | `+$3E` | FM pitch sweep — hi nibble = depth (×4 semis, downward), lo nibble = rate/tick (0 = off) |

Bytes `+$32..$34` are the **KIT/sample union** (`kit` / `gain` / `rate`) and `+$3F` is `pmode`
(PERC) — unused in an FM record. Non-FM types (KIT/WAVE/TONE/NOISE/PERC) reuse the same 64
bytes as a union.

### 2.2 Operator order — the one gotcha ⚠

The record (and `.gmi`) stores operators in **YM2612 register order**: storage slots 0–3 =
operators **1, 3, 2, 4** (because `$30/$34/$38/$3C` address ops 1,3,2,4). But most external
formats — `.tfi`/`.vgi`, VGM, Ableton, and the datasheet/modulation-routing convention — use
**logical order op1–op4 = 1,2,3,4**. So every converter applies a permutation:

- logical `op1,op2,op3,op4` → storage slots `0, 2, 1, 3`
- a register-order source (SMPS, VGM `$30…` group) → logical `1,3,2,4`

It's a one-line permutation in each tool, and the **#1 source of silent-wrong-patch bugs** —
validate against a known voice (e.g. a Sonic bass) by ear before trusting a batch.

## 3. The instrument patcher (`user-tools/genmddj-instrument-patcher.html`) — built

The browser editor for the 32 FM patches — name, algo/fb, the four operators — with the
on-console FM screen's algorithm diagram. **The killer feature is audition:** a register-level
OPN2 core (Web Audio) plays a piano of each patch as you drag, so you hear it.

It runs two ways and is a two-way converter / ripper:

- **Standalone** — an in-memory bank seeded from the factory patches, so you can convert
  patches with no ROM in sight; **or** drop a `.bin` and it patches **`GMINSTR0`** in place
  and re-checksums the MD header on export (`PALETTE.md` §5/§6 — same patcher core).
- **Import / export** `.gmi` (native, lossless), `.tfi` / `.vgi` (other YM2612 tools), and
  **Ableton Operator `.adv`** (a 4-op FM synth adapted to the YM2612 via the algorithm map +
  the envelope-time→chip-rate curve, and back out as a valid Operator preset — see `ALS.md`).
- **Import VGM** — rips patches straight from a `.vgm`/`.vgz` game log: it snapshots each
  channel's `$30–$B0` register set at every key-on, dedupes identical patches, and ranks them
  by play count. This is the **VGM extractor (§5.3) shipping inside the patcher.**

## 4. The baker (`tools/makeinstruments.py`) — built

CSV-free: it reads the `.gmi` files directly. `makeinstruments.py <src-dir> <out.bin>`
validates each record, emits the 2 KB bank, and the Makefile bakes it on every build (the
`.gmi` filenames contain spaces, so the rule is FORCE'd rather than a wildcard prerequisite).
`--b64` also prints base64 of the bank + the JS name array, handy for refreshing the
patcher's default bank. The on-console **NEW** dumps this bank into a fresh song.

## 5. Game-patch extractors

Pull FM patches out of real games. All three sources produce **YM2612-native** patches — a
**re-pack, no fidelity loss** (unlike the Ableton path in `ALS.md`, which *adapts* a different
FM engine). **VGM ships today** (in the instrument patcher, §3); **SMPS and GEMS are planned**
native re-packs. All target the §2 record (with the §2.2 permutation).

### 5.1 SMPS *(planned)*

Sega's first-party driver (Sonic + much of the catalogue); named, ordered voice banks. A
voice is **25 bytes** of raw register values:

```
byte  0      $B0  (FB<<3)|ALGO          -> fb, algo
bytes 1–4    $30  (DT<<4)|MUL  ×4 ops   -> dt, mul      (register order: 1,3,2,4)
bytes 5–8    $40  TL          ×4        -> tl
bytes 9–12   $50  (RS<<6)|AR  ×4        -> rs, ar
bytes 13–16  $60  (AM<<7)|D1R ×4        -> am, d1r
bytes 17–20  $70  D2R         ×4        -> d2r
bytes 21–24  $80  (SL<<4)|RR  ×4        -> sl, rr
```

Conversion is a re-pack, not a reinterpretation — same chip params, unpacked into the §2
record (with the §2.2 permutation). The work is *locating the voice bank*: detect the SMPS
variant by signature and follow its voice-pointer table; start with the Sonic-family SMPS
(1/2/3&K — best-documented), with a per-game offset table keyed by ROM hash as the fallback.
*Caveats:* some variants store TL with a flag bit/offset (clamp 0–127, validate); some banks
pad to 26+ bytes; voice count is in the header or implied by the pointer table.

### 5.2 GEMS *(planned)*

The common US/Western third-party driver/toolkit. Its FM instruments are likewise
YM2612-native operator params, so again a re-pack from a different container — locate the
GEMS instrument bank and parse the FM records per the documented format. *Caveats:* skip/flag
non-FM and multi instruments; same §2.2 operator-order care.

### 5.3 VGM *(built — in the instrument patcher)*

A VGM is a log of the actual chip register writes, so it works for **any** game regardless of
its driver (SMPS/GEMS/custom). The patcher walks the log, snapshots each channel's `$30–$B0`
set at every `$28` key-on → one patch, dedupes identical snapshots, and ranks by play count.
It's the broadest net (vgmrips has thousands of MD logs, and ROM→emulator→VGM feeds a
cartridge that has no parseable bank), and the **only** route for custom-driver titles like
**Streets of Rage** (Koshiro's own driver). Those patches are already chip-native, so the
snapshot is a direct re-pack; the game's PCM percussion goes to the kit/DAC separately, and
slides/vibrato live in the register *stream* as performance (→ the `P`/`L`/`C`/`F` command
layer), not in the patch.

## 6. Notes / open questions

- **Import is build-time for the *factory* bank** (edit `.gmi` → bake → ROM rebuild). For
  one-off finds, route a patch into the **SRAM user library** instead (runtime load via the
  bank editor / a `.gmi` per slot — no rebuild, fewer slots).
- **Bank size** — 32 baseline; revisit if extraction yields banks worth keeping wholesale.
- **SMPS/GEMS parsers** — the remaining extractor work; VGM already covers the long tail.
- **Op-order validation (§2.2)** — ear-test against a known voice before any batch run.
