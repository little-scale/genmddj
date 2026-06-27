# genmddj palette editor

**Plan doc — 2026-06-21.** A **browser ROM-patcher** for the UI colour schemes: import an
assembled `.bin`, edit the palettes with live NTSC/PAL-accurate previews, export a patched `.bin`.
A `user-tools/palette/` tool (`user-tools/README.md`). Unlike the instrument baker, it works on the
**finished ROM** — no toolchain, no rebuild — so anyone with a ROM can reskin it.

## 1. Workflow

```
import .bin  ──▶  locate pal_table  ──▶  edit 8 schemes  ──▶  patch 48 bytes  ──▶  re-checksum  ──▶  export .bin
```

No build step. The whole tool is one HTML page (canvas swatches + a colour picker + file I/O).

## 2. The palette data in ROM

`pal_table` — **8 schemes × 3 colours × 1 word = 48 bytes**. Each scheme:

| word | CRAM | role |
|---|---|---|
| c0 | colour 0 | background |
| c1 | colour 1 | text / cursor-block |
| c2 | colour 2 | cursor glyph (currently = bg) |

Default schemes: `0 BLK`, `1 WHT`, `2 KIDD`, `3 AMBR`, `4 CYAN`, `5 PINK`, `6 NEON`, `7 MINT`.
(`apply_palette` loads `pal_table[opt_pal]` into CRAM 0–2; `opt_pal`'s "0..3" comment is **stale** —
there are 8 — confirm the OPTIONS UI exposes all 8 when wiring the editor.)

## 3. The Mega Drive colour model

MD colour is a 16-bit word **`0000 BBBB GGGG RRRR`** (`$0BGR`) where each channel nibble holds only
**even values 0,2,4,…,E** — i.e. **3 bits / 8 levels per channel, 512 colours**. So `$0E40` =
B=`$E`(7), G=`$4`(2), R=0. The editor's job at write time is **snapping** a freely-picked colour to
the nearest legal MD value:

```
level = nearest of the 8 MD levels for each of R,G,B   (by the accurate ramp, not linear /255*7)
nibble = level << 1                                     ; 0,2,…,E
word   = (B_nibble << 8) | (G_nibble << 4) | R_nibble
```

The 8 levels are **not evenly spaced** (the MD colour DAC is non-linear), so snap and preview
against the documented MD level→sRGB ramp, not a naive linear map.

## 4. NTSC / PAL preview

Important nuance: the stored 9-bit values are **region-independent** — the VDP emits the same RGB
DAC output on NTSC and PAL, and over RGB/SCART the colours are identical. What differs is how a
region's **display** renders them (composite colour encoding, and the usual "Genesis look"). So the
tool doesn't store two palettes — it previews the *one* snapped value through **two display LUTs**:

- **NTSC LUT** — MD level→sRGB as seen on a 60 Hz composite/RGB chain.
- **PAL LUT** — the 50 Hz equivalent.

Show both swatches side by side per colour so the designer picks values that read well on either
region (genmddj already has an NTSC/PAL setting). Source the LUTs from the established MD
colour-accuracy references; expose a toggle for "ideal / NTSC composite / PAL".

## 5. Locating `pal_table` in the binary

The ROM is assembled, so `pal_table`'s address drifts between builds — a fixed offset is fragile.
Two options:

1. **Embedded marker (recommended).** Emit a magic tag immediately before the table, e.g.
   `palmark: dc.b "GMDJPAL0"` then `pal_table:`. The patcher scans the ROM for `GMDJPAL0` and edits
   the 48 bytes that follow. Robust across builds and across re-edits. Costs 8 ROM bytes + a one-line
   asm addition (the single build-side cooperation this tool needs).
2. **Content signature (no asm change).** Scan for the default scheme bytes (`$0E40 $00EE $0E40 …`).
   Works on a fresh ROM but breaks on a second edit (the bytes have changed), so the tool would have
   to remember the offset. Fine for an MVP; the marker is the durable answer.

Recommend adding the marker — it also future-proofs the **font patcher** (§7) and any later
ROM-patchers, which all want the same "find my data" anchor.

## 6. Export — re-checksum

After patching, recompute the **MD header checksum** (`fixheader.py`'s algorithm, ported to JS) so
the ROM stays valid for checkers/flashcarts. The palette bytes are well inside the data body the
checksum covers, so this is required, not optional.

## 7. Sibling: the font patcher

The font is the same kind of asset — UI tiles in ROM — and a font patcher is the **same machinery**
(import → locate by the `GMDJFON0` marker → edit/import tiles → re-checksum → export), so it's cheap
once §5/§6 exist. But the genmddj font is **not plain ASCII**, and a naïve "drop a Sega-game rip over
the whole set" would break the UI. Two things the tool must respect:

**192 tiles, two linked sets.** `makefont.py` emits **96 normal** glyphs (`$20–$7F`, the SMSGGDJ 5×7
set in an 8×8 cell) then **96 inverse** copies (foreground/background swapped) — loaded at VRAM `$20`
and `$80`, so `inverse tile = ASCII + $60`. The inverse set is the **cursor / playhead highlight
block** (colour 0 is transparent on the MD planes, so a true filled-cell highlight needs a real
inverse glyph, not just a palette swap). **Editing a glyph means editing both its normal and inverse
tile**, or the highlighted/playhead version goes stale.

**Reserved system glyphs.** Several ASCII slots are repurposed as UI symbols, not letters — lock
these by default (offer an "edit system glyphs" advanced mode):

| code | slot | UI symbol |
|---|---|---|
| `$3C` | `<` | live-queue marker (hollow ▶) |
| `$3E` | `>` | live-queue marker (solid ▶) |
| `$40` | `@` | SYNC IN (◀) |
| `$5C` | `\` | SYNC PULSE (clock pulse) |
| `$60` | `` ` `` | θ phase (FM-LFO column header) |
| `$7B` | `{` | **toggle box OFF** (hollow) |
| `$7C` | `\|` | DIR arrow **DOWN** |
| `$7D` | `}` | **toggle box ON** (solid) |
| `$7E` | `~` | DIR arrow **UP** |
| `$7F` | DEL | DIR arrow **BOTH** |

So the patcher should freely swap **letters / digits / punctuation** from a rip while **protecting
the slots above**, and propagate every edit to the matching inverse tile. (Lowercase `$61–$7A`
currently fall back to uppercase — a rip *adding* real lowercase there is safe and a nice upgrade.)

Lower priority than palette (cosmetic), but on-theme — "reskin your tracker from the Sega heritage,"
mirroring how the extractors pull *patches* from games. It and the palette tool share a small
**ROM-patcher core** (binary read, marker-find, checksum, file I/O) worth factoring out once both exist.

## 8. Open questions

- **Scheme count** — 8 in `pal_table`; confirm the OPTIONS editor + `row_max`/clamp expose 0–7 (the
  `opt_pal` "0..3" comment suggests it may currently cap at 4).
- **Marker** — add `GMDJPAL0` before `pal_table` (and an analogous tag for the font)? One tiny,
  safe asm change that unlocks both patchers.
- **LUTs** — which MD colour-accuracy reference for NTSC vs PAL; ship a couple and let the user pick.
- **Scope of c2** — cursor-glyph currently equals bg; expose it independently in the editor or keep
  the 2-colour-effective scheme?
