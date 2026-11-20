# Third-party code notice

This tool bundles a compiled WebAssembly build of **Genesis Plus GX**
(`genesis_plus_gx_libretro.js` / `.wasm`), the emulator core that actually
runs the GENMDDJ ROM. It is not original code from this project.

## License: non-commercial

Genesis Plus GX is source-available, not permissively licensed. The full
text is in [`GENESIS_PLUS_GX_LICENSE.txt`](./GENESIS_PLUS_GX_LICENSE.txt)
in this folder, copied verbatim from the upstream repository. The key term:

> Redistributions may not be sold, nor may they be used in a commercial
> product or activity.

In practice: fine for this project, for personal sites, and for any other
free, non-commercial use. Not fine if the surrounding site or product is
commercial (paid access, ads tied to the tool, etc.) without checking with
the Genesis Plus GX authors first. This notice is informational, not legal
advice, if it matters for your use case, do your own check.

The license also requires the copyright notice and license terms to travel
with any redistribution, hence this file and the full license text sitting
alongside the compiled core, and requires that modified redistributions
include complete source. The C source compiled here is unmodified upstream
Genesis Plus GX, only the Emscripten link step's target environment flag
differs from a stock build, see below for the exact recipe.

## What's bundled, and where it's from

* **Genesis Plus GX core** &mdash; Copyright (c) 1998-2003 Charles MacDonald,
  Copyright (c) 2007-2026 Eke-Eke, portions Copyright Nicola Salmoria and the
  MAME team. Source: <https://github.com/libretro/Genesis-Plus-GX>
* **Nuked OPN2** (the optional cycle-accurate YM2612 core) &mdash; Copyright (C)
  2017-2022 Alexey Khokholov (Nuke.YKT), LGPL 2.1+. Bundled inside the
  Genesis Plus GX source above; see `GENESIS_PLUS_GX_LICENSE.txt` for its
  license text.

## How the WASM build was produced

Built from an unmodified checkout of the upstream repository above, using
Emscripten, with the standard libretro core build flow and a clean, explicitly
named set of exported functions (`retro_init`, `retro_run`, etc., the normal
libretro C API). The only difference from a typical Node-targeted build of
the same core is the linker's `-s ENVIRONMENT=` flag, set to `web,worker`
here instead of `node`, so it runs in a browser tab instead of a server
process. Nothing in the Genesis Plus GX C source itself was changed.

Anyone can reproduce this build from the upstream source with a standard
Emscripten toolchain and the libretro build convention
(`emmake make -f Makefile.libretro platform=emscripten`), linking with:

```
-s ENVIRONMENT=web,worker -s MODULARIZE=1 -s EXPORT_ES6=1 -s ALLOW_MEMORY_GROWTH=1
-s EXPORTED_FUNCTIONS=[...the standard retro_* API + malloc/free...]
-s EXPORTED_RUNTIME_METHODS=[ccall,cwrap,addFunction,removeFunction,HEAPU8,...,FS]
-s FILESYSTEM=1
```
