# Ableton → genmddj converters

**Plan doc — 2026-06-21.** Two related tools, sharing the FM-adaptation core:
- **`.als` → genmddj song** — MIDI clips (up to 10 tracks) repackaged as chains/phrases, the
  first six tracks' **Operator** (4-op FM) instruments adapted to the YM2612, and (built
  2026-06-28) the PSG tracks' **Analog** (`UltraAnalog`) instruments roughly adapted to the
  TONE voice (see §2.7).
- **`.adv` → genmddj instrument** — a single Operator preset adapted to one instrument record.

Both emit the **`PRESETS.md` instrument CSV** for their FM voices, so `.adv` is the FM core
standalone and a fourth front-end to the preset pipeline (alongside SMPS / VGM). `.als` adds the
song-structure layer on top. Build `.adv` first — it validates the FM map in isolation.

## 1. Scope (locked)

Deliberately narrowed to the tractable, high-value path:
- **MIDI clips only** (audio onset/pitch detection is out of scope).
- **Operators are sine** — Operator's other operator waveforms are read as sine; ratio/level/
  envelope still map, the non-sine harmonics are simply not reproduced. No approximation attempts.
- **Monophonic — highest note wins.** At each 16th, if a clip has a chord, keep the top note. No
  voice-allocation, no arp.
- **Note-ON only.** Note-offs are *not* mapped. A note rings until the next note-on retriggers its
  (mono) channel — see §3.4. This means the envelope **Release (RR) is dormant** and decay is
  shaped by Sustain/D2R while the note rings.
- **Velocity → `X` is optional** (a flag). Off = uniform instrument volume.
- 16th-note grid, 4/4 assumed (triplets/odd meters quantise lossily).

## 2. The FM adaptation — Operator → YM2612

Both are 4-op FM, so this is a parameter re-map, not a re-synthesis. Output is the `PRESETS.md`
FM record. Operator ops **A,B,C,D** map to the YM2612's four operators; feedback lives on A → op1.

### 2.1 Level → TL  *(quantise operator levels to TL)*
YM2612 `TL` is 0–127, **inverted** (0 = loudest) at ~**0.75 dB/step** (≈96 dB range). Operator's
operator level is a dB-ish 0–127 (127 = loudest). So:

```
TL = clamp( round( (OP_LEVEL_MAX - op_level_dB) / 0.75 ), 0, 127 )
```

Carriers' levels become the patch's output level; modulators' levels become the **modulation
index** (brightness) — same formula, the algorithm decides which is which. *Calibrate* the exact
curve against Operator's level scaling once (it's close to linear-in-dB).

### 2.2 Coarse → MUL  *(import MUL from coarse tuning)*
`MUL` is 0–15 where **0 = ×0.5**, 1–15 = ×1…×15.

```
coarse 0.5            -> MUL 0
coarse N (int 1..15)  -> MUL N
coarse > 15           -> clamp 15 (flagged lossy)
fine / fractional     -> DT best-effort, else dropped (DT is a small fixed offset, not cents)
```

Most musical FM ratios are small integers, so this is clean in practice.

### 2.3 Envelope: time → rate  *(convert time scales + constants)*
The hard conversion. Operator A/D/R are **times (ms)**; YM2612 AR/D1R/D2R are **rates 0–31** (RR is
0–15), nonlinear and EG-clock-paced. The EG timing is documented (e.g. Nuked-OPN2 tables): time
falls roughly **×0.5 per +4 of (rate + key-scale)**. So:

```
rate(t) = clamp( round( R_MAX - 4 * log2( t / T_MIN ) ), 0, 31 )   # 0..15 for RR
```

with `T_MIN` / `R_MAX` taken from the YM2612 EG rate→time table (the "constants"). Build a single
calibrated lookup `ms -> rate` and reuse it for AR (attack), D1R (decay), RR (release).

### 2.4 ADSR mapping  *(make the envelope possible)*
Operator's Attack(time)/Decay(time)/Sustain(level)/Release(time) → the YM2612's five-stage EG:

| Operator | YM2612 | Notes |
|---|---|---|
| Attack time | `AR` | via §2.3 |
| Decay time | `D1R` | rate from peak down to `SL` |
| Sustain level | `SL` (0–15) | **inverted**: `SL = clamp(round((1 - sustain) * 15), 0, 15)` |
| (sustain slope / hold) | `D2R` | 0 = hold at `SL`; map a sustain-decay slope here if present |
| Release time | `RR` | via §2.3 — **dormant** under note-on-only (§1) |

### 2.5 Algorithm match  *(match the FM algo)*
Map Operator's 11 algorithms to the YM2612's 8 by **modulation topology** (which ops are carriers,
who modulates whom). Clear endpoints:

```
A→B→C→D  (series, 1 carrier)      -> YM2612 ALG 0
A→B , C→D (two 2-op stacks)        -> YM2612 ALG 4
A→(B,C,D)                          -> YM2612 ALG 5
A→B + C + D                        -> YM2612 ALG 6
A , B , C , D  (parallel/additive) -> YM2612 ALG 7
```

The middle configs (one/two modulators feeding a shared carrier → ALG 1/2/3) need a **curated
11→8 table**; a handful of Operator routings have no exact YM2612 twin and take the nearest. This
table is small, static, and the thing to validate by ear first.

### 2.6 Dropped / dormant
Non-sine waveforms (harmonics lost), the filter, built-in FX, unison/voices, the global pitch
envelope, fine-cent ratios, and — under note-on-only — Release. Operator's LFO partially maps to
`AMS`/`FMS` + the global `$22` LFO if present; otherwise dropped.

### 2.7 Analog (`UltraAnalog`) → PSG TONE  *(built 2026-06-28, rough)*
The **PSG** tracks (S1–S3) with an Ableton **Analog** device get a rough TONE patch instead of a
bare default (`analogToTone` in `als2genmddj.html`). **Oscillator/voice 1 only** — Analog repeats
every param per voice; we always take the first occurrence and ignore osc 2. The **amp envelope**
(`<Envelope.1>` — the loudness one; `AMP_ENV` constant, flip to 0 if inverted) ADSR maps to the
TONE **AHD** envelope: `AttackTime → ip_atk`, `SustainLevel → ip_hld` (high sustain = long/∞ hold),
`Decay`/`Release → ip_dcy`, peak `ip_vol = 15` — all the 0–1 Analog values scaled to tick counts.
The **LFO** (when `LFOToggle` is on) maps `OscillatorLFOModPitch → vibrato (ip_vib)` and
`AmplifierLFOAmpMod → tremolo (ip_trm)`, with `LFOSpeed → the speed nibble`. No Analog device →
the old default TONE. Filter, the 2nd osc, FX, and sub-row detail are dropped.

## 3. The `.als` song conversion

`.als` is gzipped XML → parse tracks, clips, devices, tempo.

### 3.1 Track → channel routing
10 channels: F1–F6 (FM), T1–T3 (PSG square), NO (noise). The **first six FM-eligible tracks** (those
with an Operator device) → F1–F6 with §2 adaptation; simple melodic tracks → the PSG squares;
drum/perc → NO + the DAC kit. A track without a usable instrument maps notes only (default voice).

### 3.2 Clip → phrases → chain
1 phrase = 1 bar = 16 sixteenths. A clip's bars become phrases; the run of bars becomes a chain.
**Dedup identical bars** to one pooled phrase (a 4-bar loop with 2 unique bars → 2 phrases, chain
`[0,1,0,1]`) — this is the repackaging win, and the hook for a future transpose-detector (repeat
up a 5th → one phrase + chain transpose).

### 3.3 Note → row
Per 16th: quantise note-ons to the nearest 16th; **keep the highest** if several. Write `note` +
`instrument`; if velocity→`X` is enabled, add `X = velocity >> 3` (0–15). Nothing else per row.

### 3.4 No note-off → ring-until-retrigger
Because note-offs aren't mapped, a note sounds until the **next note-on on that channel** retriggers
it (the engine is mono per channel). So perceived note length = gap to the next note, and the
patch's Sustain/`D2R` shapes the decay during that gap. Plucky/decaying patches sound right;
true pads ring for the whole gap (acceptable, and authentic to how mono chip voices behave).

### 3.5 Arrangement → SONG
The arrangement timeline (clip order over time, per track) → the SONG matrix rows (each channel's
column = its sequence of chains). Tempo → `proj_tmpo`. Swing/sub-16th → `W`/grooves (lossy, later).

## 4. The `.adv` instrument conversion

`.adv` = one Ableton device preset (gzipped XML, a single Operator). Parse → §2 → **one `PRESETS.md`
CSV row**. No song layer. This is the cleanest tool and the right first build: it isolates and
proves the FM map, and it drops a converted patch straight into the preset bank (→ baker → ROM) or
the browser editor for A/B against the original via the shared JS YM2612 core.

## 5. Build order & open questions

- **Order:** `.adv` (FM core, → CSV) → validate the §2 tables by ear → `.als` (add §3 song layer).
- **Calibrate §2.1 (level curve) and §2.3 (time→rate) once**, against a few known Operator patches
  A/B'd in the browser editor — these two tables are where fidelity lives.
- **§2.5 algo table** — pin and ear-test before batch runs (the §2.2.2-style silent-wrong risk).
- **Velocity curve** — `>>3` linear, or a softer perceptual curve? (flag-gated either way.)
- **Track-routing heuristic** — auto (detect Operator → FM) vs an explicit per-track map in a
  sidecar; auto first, manual override later.
- **Ring-until-retrigger (§3.4)** — offer an optional auto-`K` (cut after N empty rows) for users
  who want shorter notes without true note-off handling? Out of scope for v1.

*The §2 FM map is shared by both tools and emits the `PRESETS.md` schema — that schema is still the
spine; this doc just adds Ableton as a source and the song-structure layer.*
