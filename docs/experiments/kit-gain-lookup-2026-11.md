# KIT real-time gain lookup experiment

**Status:** Abandoned after emulator and hardware testing  
**Baseline:** genmddj v0.25, commit `7a2ee129336d3b3ee79bb0f7a63adbfcb260e984`  
**Experimental branch:** `codex/kit-realtime-gain`

## Objective

Replace the five pre-baked KIT PCM pools (`full`, `/2`, `/4`, `/8`, `/16`) with one
full-resolution PCM pool and apply the established volume mapping during playback. The
goal was to recover ROM capacity without changing KIT volume, pitch, duration, mute or
retrigger behaviour.

## Prototype design

- The ROM stored one full PCM pool instead of five.
- Five page-aligned 256-byte tables reproduced the exact unsigned, `$80`-centred mappings.
- The 68k sent the effective attenuation level to the Z80 when arming a sample.
- The Z80 selected a lookup page once per trigger, prepared the next scaled byte between
  Timer-A overflows, cached it in the `I` register, and wrote the cached byte in the
  timing-critical DAC feed pass.
- Byte preparation and one bounded PSG/YM mailbox unit shared each non-feed pass.

## Measured benefit

| Item | v0.25 | Prototype |
|---|---:|---:|
| Sample pool | 1,395,752 bytes | 282,440 bytes |
| Z80 driver | 780 bytes | 2,304 bytes |
| Net ROM capacity recovered | — | 1,111,788 bytes (about 1.06 MiB) |

The full PCM pool was byte-for-byte identical to the first v0.25 pool. Every entry in
all five lookup pages also reproduced the corresponding v0.25 pre-shifted pool exactly.

## Automated results

- The complete 45-test headless regression suite passed.
- All audible KIT levels retained their expected approximately 6 dB steps; mute was silent.
- Retrigger attenuation, natural sample end and a 32 KB ROM-bank crossing passed.
- Dense simultaneous DAC, YM2612 and SN76489 traffic continued to be delivered.
- Genesis Plus GX reported the same median DAC count as v0.25: about 170 writes per frame.

## Failure found by listening

The prototype sounded clearly degraded in both emulation and on real hardware. The
mathematical output bytes and average feed count were correct, but those measurements did
not establish uniform spacing between individual DAC writes. The extra per-byte read,
lookup and scheduling work changed the temporal behaviour of the feed loop. Uneven DAC
write spacing is the leading explanation for the audible roughness, although the prototype
was abandoned rather than treating that explanation as conclusively proven.

An earlier A/B capture also had poor waveform correlation with v0.25. That should have
been treated as a failed acceptance test even though aggregate cadence and amplitude-ratio
checks passed.

## Decision

Retain the v0.25 implementation: five pre-baked PCM gain pools selected by address, with
one direct ROM read in the critical Z80 DAC path. For this driver, deterministic timing and
sound quality are more valuable than the recovered ROM space.

Do not revive this exact lookup/cache design without a test that measures individual DAC
write intervals—or a cycle-accurate trace—and an A/B audio acceptance test on hardware.
Any future space-saving design should keep per-byte work out of the Z80 feed schedule.
