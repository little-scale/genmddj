# genmddj command-set reconciliation

**Working doc — started 2026-06-21.** Reconciles the **spec'd** command set (DESIGN.md §8),
the **SMSGGDJ** reference set (sms_tracker/DESIGN.md §8), and what is **actually built**,
in light of everything implemented so far (per-channel FM, the FM LFO bank, the WAVE/DAC
engine, the 5327 Hz DAC, the macro tables). Captures **decisions + justifications** before
implementing. Companion to DESIGN.md §8 — when a decision here changes §8, update §8 too.

The command column is a phrase/table cell `(letter A–Z = 1..26, param byte)`. One executor
runs both columns; voice-type-specific commands no-op on inapplicable voices.

---

## 1. Status at a glance

| Cmd | Name | Voices | Built? | Reconcile (see §3/§4) |
|---|---|---|---|---|
| `A` | tAble (start/switch macro table) | all | ✗ | depends on M9-tables (#9) |
| `B` | wave Bank (one-shot wave#) | WAVE/sample | ✗ | **range 0–7 → 0–F** (16 waves built) |
| `C` | Chord (0,x,y arp) | all | ✗ | as spec'd |
| `D` | Delay (trigger +N ticks) | all | ✗ | as spec'd |
| `E` | Envelope (re-slope AHD / FM AR-RR) | all | ✗ | FM half needs per-channel reg write |
| `F` | Finetune (period / F-num delta) | tone/FM | ✗ | FM half = per-channel $A0/$A4 |
| `G` | Groove switch | global | ✗ | as spec'd |
| `H` | Hop (per-channel phrase end / table loop) | all | **✓** | OK |
| `I` | Iteration (deterministic play-mask) | all | **✓** | OK |
| `J` | reserved | — | — | **candidate: LFO command** (§3.4) |
| `K` | Kill (note cut after N) | all | ✗ | as spec'd; aborts PCM |
| `L` | sLide (tone portamento) | tone/FM | ✗ | FM half = per-channel F-num ramp |
| `M` | aMp mod (tremolo) | all | partial (PSG) | **FM path TBD vs LFO bank** (§3.3) |
| `N` | Noise mode/rate | NO | ✗ | as spec'd |
| `O` | Output / pan (YM2612 L/R) | FM/DAC | ✗ | **per-channel $B4 write** (§3.1) |
| `P` | Pitch bend | tone/FM | ✗ | FM half = per-channel F-num |
| `Q` | fm timbre (ALGO+FB) | FM | **✓ (F1-only)** | **make per-channel** (§3.1) |
| `R` | Retrig (vol-step every N) | all | ✗ | as spec'd |
| `S` | Speed (sample data-walk) | sample | ✗ | rate-independent; OK at 5327 (§3.2) |
| `T` | Tempo (BPM→groove) | global | ✗ | as spec'd |
| `U` | mod level (modulator TL sweep) | FM | ✗ | **per-channel modulator $40** (§3.1) |
| `V` | Vibrato (one-shot) | tone/FM | partial (PSG) | **FM path TBD vs LFO bank** (§3.3) |
| `W` | Wait-skip (shorten row) | global | ✗ | as spec'd |
| `X` | volume (PSG atten / FM carrier TL) | all | **✓ (F1-only)** | **make per-channel** (§3.1) |
| `Y` | fm Voice (adopt patch xx) | FM | ✗ | **per-channel patch swap** (§3.1) |
| `Z` | reserved (random) | — | — | keep — the RNG counterpart to `I` |

Built: **4 / 24** (H, I, Q, X). Q and X work **only on F1**.

---

## 2. The set is sound; the work is mostly *implementation*

DESIGN §8 is a good port — it already kept SMSGGDJ's A–Z and grew the FM-native commands
(`Q` ALGO+FB, `U` modulator TL, `Y` patch adopt, `O` YM2612 pan, `X` extended to FM carrier
TL). Nothing in the *letter assignment* needs to change. The gaps are (a) only 4 are built,
and (b) several built/spec'd FM commands assume the old **F1-only** chip path. So this
reconciliation is less "redesign the set" and more "**finish it, and make the FM commands
per-channel and targeted**."

---

## 3. Cross-cutting decisions (the load-bearing ones)

### 3.1 Live FM commands must be **per-channel and targeted** (was F1-only)  ⟵ highest priority
**Finding.** The built `Q`/`X` (and spec'd `U`/`Y`) set the **global** `live_algo`/`live_vol`/
`live_fb` and raise the single `repatch` flag, which re-pushes **F1's** patch via
`ym_build_patch`. That is the same F1-only limitation we just fixed for the operator patch
itself (commit 23a7e4b). On F2–F6 these commands currently mis-target F1.

**Decision.** Live FM commands write the **specific chip register(s) for the playing
channel**, composed directly into that channel's SCB writes (using its `c_ympart` /
`c_ymchreg`), *not* a full repatch. This is per-channel by construction, cheap (1–4 regs),
and matches the diff/shadow philosophy ("only update the regs that need updating").

| Cmd | Target register(s) (channel-relative) |
|---|---|
| `Q xy` ALGO+FB | `$B0` ← `(FB<<3)\|ALGO` |
| `X xx` carrier TL | `$40+slot` for each **carrier** slot ← TL + atten |
| `U xx` modulator TL | `$40+slot` for each **modulator** slot ← base TL + offset |
| `O xy` pan | `$B4` ← `(pan<<6)\|(AMS<<4)\|FMS` (preserve AMS/FMS) |
| `Y xx` patch adopt | full `emit_ch_patch` but sourced from instrument *xx* (one-shot timbre swap; does not change `c_instr`, and must update `pshadow` so the channel re-patches back on the next note) |

**Justification.** Keeps the editor's F1 live-edit path (`repatch` + `ym_build_patch`)
untouched for *editing*, but playback commands stop borrowing it. Targeted writes also keep
the per-tick SCB small (the global override + full-repatch approach cost ~27 writes per use).
The transient-override globals (`live_algo`/`live_vol`/`live_fb`) become **edit-screen-only**
(the `Q`/`X` *audition while editing F1*), or are retired once the editor uses the same
targeted path. **To verify:** these are FM register edits headless audio can't judge — confirm
by ear (per the FM-silence lesson).

### 3.2 `S` (sample speed) is unaffected by the 5327 Hz resolution
`S` re-walks the stored PCM faster/slower (decimate / hold) at the fixed Timer-A cadence, so
it's a *data-walk*, independent of the actual rate. It works the same at 5327 Hz as at the
old 17,756 Hz target. **No command change.** (Doc debt elsewhere: DESIGN §10.4 still says
k=3 → 17,756 Hz; reality is k=10 → 5327 Hz — fix in §10.4, not here.)

### 3.3 `M` (tremolo) / `V` (vibrato) on FM vs the LFO bank — **defer the FM path**
PSG `M`/`V` are built (the SWP/VIB/TRM work: per-channel software LFOs `c_modph`/`c_modph2`).
For **FM** there are three possible engines, and they overlap:
1. the **chip global LFO** (`$22`) + per-instrument **AMS/FMS** — native, cheap, but **one
   shared rate** for all FM channels;
2. a **software per-channel LFO** like the PSG path — per-channel but costs 68k cycles;
3. the **FM LFO bank** (16 software LFOs, any param, persistent per assignment) — already
   built, and *strictly more powerful* than a one-shot `M`/`V`.

**Decision.** The FM LFO bank is the home for deep/persistent FM modulation; `M`/`V` stay
the **quick per-note** override. Implement the FM `M`/`V` path **last**, and when we do,
prefer routing to the **chip LFO + AMS/FMS** (option 1) for cost, accepting the shared-rate
limitation, since anyone needing per-channel/independent modulation uses the LFO bank.
**Justification:** avoids a second per-channel software LFO engine duplicating the bank;
keeps `M`/`V` cheap; no letter change.

### 3.4 Reserved letters — `J` is the natural home for an **LFO command**
The FM LFO bank is screen-edited only; there is no way to *trigger / retrigger / gate* an
LFO from a phrase or table. Candidate for the reserved `J`:
- `J xy` — e.g. *retrigger / enable / disable* LFO slot `x` (with `y` = action or phase),
  so a table can sync a sweep to a note, or a phrase can turn a tremolo on for a section.

Keep `Z` reserved for **random** (the stochastic counterpart to `I`'s deterministic mask).
**Decision:** don't commit `J` yet — note it as the leading candidate; the LFO bank's
trigger model (NOTE/PHRASE/FREE resync already exists) should drive the exact semantics.

### 3.5 `B` (wave bank) range: **0–7 → 0–F**
The WAVE engine ships **16** drawn waves (0–F); SMSGGDJ's `B` was 0–7. Widen the param to a
single hex digit 0–F. Trivial; note it so the editor param-formatter and §8 agree.

---

## 4. Implementation priority (when we build, not yet)

1. **Reconcile the FM live commands to per-channel/targeted** (§3.1): fix `Q`/`X`, add
   `U`/`O`/`Y`. This is the direct continuation of the per-channel FM fix and unblocks real
   FM expressiveness on all 6 channels. *Highest value, and the riskiest to verify (ear-only).*
2. **The cheap, universally-useful, voice-agnostic ones**: `C` (chord), `D` (delay),
   `K` (kill), `R` (retrig), `G`/`T`/`W` (timing), `X` already done. These work from the
   shared executor and benefit phrase + table immediately.
3. **`A` (table) + the macro-table subsystem** (#9) — `A`/`H`-loop are the table's own
   control, so they land with the table work.
4. **Tone/FM pitch family**: `F` (finetune), `L` (slide), `P` (pitch bend) — FM halves are
   per-channel F-number writes (mirror §3.1's targeting).
5. **`E` (envelope reslope)** — PSG ramps (have the model) + FM AR/RR per-channel writes.
6. **Voice-specialised**: `N` (noise), `S` (sample speed), `B` (wave bank).
7. **`M`/`V` FM path** (§3.3), then **`J`** (LFO command, §3.4) once its semantics settle.
   `Z` (random) last, gated on an RNG decision.

---

## 5. Decisions (settled 2026-06-21) + remaining open items

**Settled:**
- **FM audition target** (§3.1): the FM live-edit / audition voice = **the last FM instrument
  selected in a phrase AND the last track that phrase was on** (not always F1). Track an
  `aud_track` (the FM channel) + `aud_instr` and route `ym_build_patch` / the editor audition
  to them. Playback commands still target their own running channel.
- **FM `M`/`V`** (§3.3): use the **chip global LFO** (`$22`) + per-instrument **AMS/FMS** —
  the shared rate is accepted. And **expose all the chip-LFO parameters** (LFO enable + rate,
  per-operator AMS/FMS) in the FM instrument editor (and as command params where it fits), so
  the native FM modulation is fully reachable. No per-channel software FM LFO (the LFO bank
  covers anything deeper).

**Still open:**
- **§3.4:** `J` LFO-command semantics — retrigger only, or enable/disable too? Tie to the
  bank's existing NOTE/PHRASE/FREE resync.
- **Param widths / editor formatting** per command — fold into the table as we implement.

## 6. Implementation log (as built)

**Built (per-channel, ear-test individually):** H, I (pre-existing) + the new batch —
- **Q xy** ALGO+FB → `$B0` (live slot `lq_*`, emitted in `compose_fm`).
- **X xx** carrier volume → carrier `$40` (TL + `(15-vol)*8` atten) via `emit_x_tl`.
- **O xy** pan → `$B4` bits 7/6 (x=L, y=R), preserving instrument AMS/FMS.
- **U xx** modulator TL offset → modulator `$40` via `emit_u_tl` (brightness/filter).
- **K xx** note cut after xx ticks → `c_hold` (the gate countdown). *(PCM-abort TBD)*
- **T xx** tempo → `proj_tmpo` (row-advance = `1250/proj_tmpo`).
- **F xx** finetune → per-channel signed `c_pfine`, added to the PSG period (each tick) and
  the FM 11-bit F-number (at the freq send). Static detune; rides the existing freq path.
- **C xy** chord/arp (**PSG side**) → per-channel `c_chord`/`c_cphase`; `hold_tick` cycles the
  phase 0→1→2, `env_ch` adds `[0,+x,+y]` to the effective note each tick. FM side waits on the
  per-tick FM-freq path.

All FM live commands are now per-channel/targeted (§3.1) — F1-F6, not F1-only, no repatch.

**Remaining — grouped by the engine hook each needs (next batches):**
- *Patch-source*: **Y xx** (adopt instrument xx's patch; needs `emit_ch_patch` from a chosen
  instr + a per-note revert).
- *Time-varying pitch* — **C** chord/arp, **P** bend, **L** slide. These change pitch *every
  tick*, but **FM only sends frequency on note-trigger today** — so they need a new per-tick
  FM-freq update path (PSG already recomputes its period each tick, so the PSG side is ready).
  This is the real next sub-batch (F already added the per-channel `c_pfine` offset they build on).
- *Trigger / gate timing*: **D** delay (hold the trigger N ticks), **R** retrig (re-key every
  N, step vol).
- *Global timing*: **G** groove (needs the groove array — DESIGN §9; the engine currently runs
  a flat `proj_tmpo`, so groove may be a prerequisite), **W** wait-skip (shorten this row).
- *Voice-specialised*: **N** noise mode/rate (NO ch), **S** sample data-walk (DAC), **B** wave
  bank (WAVE), **E** envelope reslope (PSG ramps + FM AR/RR per-channel writes).
- *FM modulation via the chip LFO* (decision §5): **M** tremolo, **V** vibrato — set AMS/FMS +
  `$22` enable/rate; first expose those params in the FM editor.
- *Blocked*: **A** table — lands with the macro-table subsystem (task #9).

**Audition retargeting** (§3.1 / §5): `ym_build_patch` still uses F1 for the editor audition —
route it to `aud_track`/`aud_instr` (last FM instrument + last track a phrase was on).
