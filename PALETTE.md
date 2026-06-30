# genmddj palette + font patchers

Two **browser ROM-patchers** that reskin a finished `genmddj.bin` — no toolchain, no
rebuild, so anyone with a ROM can recolour the UI or replace the font. Both ship in
`user-tools/`:

- **`genmddj-palette-patcher.html`** — the 8 UI colour schemes (`GMDJPAL0`).
- **`genmddj-font-patcher.html`** — the 8×8 UI font (`GMDJFON0`), §7.

They're the post-build, *patched* half of the data pipeline (the default `pal_table` /
`font.bin` are still **baked** from source by `make`); see `user-tools/README.md` for how
baked / patched / runtime-loaded data fit together.

## 1. Workflow

```
import .bin  ──▶  locate GMDJPAL0  ──▶  edit 8 schemes  ──▶  patch 48 bytes  ──▶  re-checksum  ──▶  export .bin
```

No build step. The whole tool is one HTML page (canvas swatches + a colour picker + file I/O).

## 2. The palette data in ROM

`pal_table` — **8 schemes × 3 colours × 1 word = 48 bytes**, immediately after the
`GMDJPAL0` locator. Each scheme:

| word | CRAM | role |
|---|---|---|
| c0 | colour 0 | background |
| c1 | colour 1 | text / cursor-block |
| c2 | colour 2 | cursor glyph (currently = bg) |

Default schemes: `0 BLK`, `1 WHT`, `2 KIDD`, `3 AMBR`, `4 CYAN`, `5 PINK`, `6 NEON`,
`7 MINT`. `apply_palette` loads `pal_table[opt_pal]` into CRAM 0–2; the OPTIONS **PALETTE**
field selects the active scheme, and changes apply instantly and persist in SRAM. (The
`opt_pal` source comment still reads "0..3" — stale; the table and the patcher carry all 8.)

## 3. The Mega Drive colour model

MD colour is a 16-bit word **`0000 BBBB GGGG RRRR`** (`$0BGR`) where each channel nibble
holds only **even values 0,2,4,…,E** — i.e. **3 bits / 8 levels per channel, 512 colours**.
So `$0E40` = B=`$E`(7), G=`$4`(2), R=0. The patcher's job at write time is **snapping** a
freely-picked colour to the nearest legal MD value:

```
level = nearest of the 8 MD levels for each of R,G,B   (by the accurate ramp, not linear /255*7)
nibble = level << 1                                     ; 0,2,…,E
word   = (B_nibble << 8) | (G_nibble << 4) | R_nibble
```

The 8 levels are **not evenly spaced** (the MD colour DAC is non-linear), so snap and
preview against the documented MD level→sRGB ramp, not a naive linear map.

## 4. NTSC / PAL preview

The stored 9-bit values are **region-independent** — the VDP emits the same RGB DAC output
on NTSC and PAL, and over RGB/SCART the colours are identical. What differs is how a
region's **display** renders them (composite colour encoding, the "Genesis look"). So the
tool stores one snapped value and previews it through **two display LUTs** — an **NTSC** and
a **PAL** one — side by side per colour, so you pick values that read well on either region
(genmddj has an NTSC/PAL setting). The LUTs come from the established MD colour-accuracy
references, with an "ideal / NTSC composite / PAL" toggle.

## 5. Locating data — the embedded markers

The ROM is assembled, so addresses drift between builds — a fixed offset is fragile.
Instead each patchable asset sits right after a **magic locator** the tool scans for:

| Marker | Asset | Bytes |
|---|---|---|
| `GMDJPAL0` | `pal_table` (this tool) | 48 |
| `GMDJFON0` | the UI font (§7) | 192 tiles |
| `GMINSTR0` | the FM factory bank (`PRESETS.md`) | 32 × 64 |
| `GMDJWAV0` | the wavetable defaults (the wave editor) | 16 × 32 |

Robust across builds and across re-edits — the same "find my data" anchor every
ROM-patcher uses, and the reason the palette / font / instrument / wave patchers can share
one core (binary I/O, marker-find, checksum).

## 6. Export — re-checksum

After patching, the patcher recomputes the **MD header checksum** (`fixheader.py`'s
algorithm, ported to JS) so the ROM stays valid for checkers and flashcarts. The edited
bytes are well inside the data body the checksum covers, so this is required, not optional.

## 7. The font patcher

The font is the same kind of asset — UI tiles in ROM — patched the same way (import →
locate `GMDJFON0` → edit / import tiles → re-checksum → export). genmddj's font is **not
plain ASCII**, so the patcher respects two things:

**192 tiles, two linked sets.** `makefont.py` emits **96 normal** glyphs (`$20–$7F`, the
SMSGGDJ 5×7 set in an 8×8 cell) then **96 inverse** copies (fg/bg swapped) — loaded at VRAM
`$20` and `$80`, so `inverse tile = ASCII + $60`. The inverse set is the
cursor / playhead highlight block (colour 0 is transparent on the MD planes, so a true
filled-cell highlight needs a real inverse glyph, not just a palette swap). **Editing a
glyph edits both** its normal and inverse tile — the patcher derives the inverse
automatically.

**Reserved system glyphs.** Several ASCII slots are repurposed as UI symbols, not letters —
locked by default (with an "edit system glyphs" advanced mode):

| code | slot | UI symbol |
|---|---|---|
| `$3C` | `<` | live-queue marker (hollow ▶) |
| `$3E` | `>` | live-queue marker (solid ▶) |
| `$40` | `@` | SYNC IN (◀) |
| `$5E` | `^` | SYNC IN24 (« double-left chevron) |
| `$5C` | `\` | SYNC PULSE (clock pulse) |
| `` $60 `` | `` ` `` | θ phase (FM-LFO column header) |
| `$7B` | `{` | toggle box OFF (hollow) |
| `$7C` | `\|` | DIR arrow **DOWN** |
| `$7D` | `}` | toggle box ON (solid) |
| `$7E` | `~` | DIR arrow **UP** |
| `$7F` | DEL | DIR arrow **BOTH** |

So the patcher freely swaps **letters / digits / punctuation** (e.g. from a Sega-game font
rip) while protecting the slots above and propagating each edit to the inverse tile.
Lowercase `$61–$7A` currently fall back to uppercase, so a rip *adding* real lowercase
there is a safe upgrade. Besides ROM-patching `GMDJFON0`, the tool can also save `font.bin`
for a build-time bake (`tools/font_custom.bin` + `make`).
