# GENMDDJ Web Player

A browser version of `user-tools/player/genmddj-player`, the offline `.gmdj`
renderer. Same idea, no build step and no command line: open `index.html`
(served over http(s), not `file://`, browsers block WASM+fetch there),
upload a `.gmdj`, click Render.

```sh
cd user-tools/webplayer
python3 -m http.server 8080
# open http://127.0.0.1:8080
```

## What it does

Runs the real GENMDDJ ROM through a WebAssembly build of Genesis Plus GX,
entirely in the browser tab. No server-side processing, nothing uploaded
anywhere, everything (ROM, emulator core, your song) stays local to the page.

* Renders the main stereo mix, the 10 individual hardware-voice stems, or both
* Play results back immediately with the built-in `<audio>` players, or download them
* Multiple outputs (stems) can be downloaded together as one `.zip`
* Drag-and-drop or click to choose a `.gmdj`

## Getting a `.gmdj` to render

Use `user-tools/genmddj-savetool.html` to extract one from a cart save
(`.sav`/`.srm`), or use one already extracted.

## Files in this folder

* `index.html` &mdash; the whole tool, self-contained
* `genesis_plus_gx_libretro.js` / `.wasm` &mdash; the emulator core (see `NOTICE.md`
  for license terms; it's non-commercial-use software, not this project's own code)
* `genmddj.bin` &mdash; the ROM the player runs your song through
* `NOTICE.md`, `GENESIS_PLUS_GX_LICENSE.txt` &mdash; third-party attribution and license text

## Hosting this yourself

All six files need to sit together in the same folder on any static web
host, GitHub Pages, your own site, wherever. No server-side code involved.
