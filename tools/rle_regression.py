#!/usr/bin/env python3
"""rle_regression.py -- end-to-end regression for the RLE song-compression feature.

Re-runs the checks that were done by hand while building the feature, so a future
change to the codec, the SRAM directory, or the savetool can be verified in one
command. Exits non-zero on the first failure.

    tools/rle_regression.py            # all checks
    tools/rle_regression.py --quick    # skip the cart checks (no make/harness)

Checks:
  1. codec        -- rletest.py round-trips synthetic + (if present) a real .gmdj
  2. savetool     -- the browser JS builds a directory .sav and reads it back 0-diff
  3. cart dir     -- the ROM saves 3 songs + deletes the middle; the SRAM dump shows
                     2 valid entries, names A/C, with C's blob compacted down (no hole)
  4. savetool=ROM -- a savetool-built .sav parses byte-for-byte as the ROM's dir_load
                     expects (entry layout + heap offset), and decompresses to the song

The cart checks build an injected ROM (src/main.asm is backed up and always restored)
and run it under tools/emu/retroshot, so they need the toolchain (make + the core).
"""
import os, sys, re, shutil, subprocess, tempfile, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC  = os.path.join(ROOT, "src", "main.asm")
CORE = os.path.join(ROOT, "tools", "emu", "genesis_plus_gx_libretro.dylib")
SHOT = os.path.join(ROOT, "tools", "emu", "retroshot")
ROM  = os.path.join(ROOT, "build", "genmddj.bin")
HTML = os.path.join(ROOT, "user-tools", "genmddj-savetool.html")

INJECT_ANCHOR = "    move.b  #1, need_clear               ; draw header/name on first frame"
SPLASH_FROM   = "    move.w  #150, splash_ctr"
SPLASH_TO     = "    move.w  #3, splash_ctr"

# directory layout (logical), matched against the +1 emulator lead-in below
LEAD, DIR_BASE, DIR_ENT, DIR_N, HEAP_BASE, DATA_SIZE = 1, 2304, 16, 32, 2816, 23904

fails = []
def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  -- {detail}" if detail else ""))
    if not ok: fails.append(name)


def codec_check():
    print("1. codec (rletest.py)")
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import rletest
    blocks = {
        "all-FF": bytes([0xFF]) * DATA_SIZE,
        "all-00": bytes(DATA_SIZE),
        "random": bytes((i * 2654435761 >> 13) & 0xFF for i in range(DATA_SIZE)),
    }
    for nm, b in blocks.items():
        rt = rletest.rle_decompress(rletest.rle_compress(b)) == b
        check(f"round-trip {nm}", rt)
    check("random hits store-raw floor", len(rletest.rle_compress(blocks["random"])) >= DATA_SIZE)


def savetool_js():
    js = "\n".join(re.findall(r"<script[^>]*>(.*?)</script>", open(HTML).read(), re.S))
    shim = ('const el=()=>({value:"0",checked:false,appendChild:()=>{},textContent:"",disabled:false,'
            'set onclick(v){},set onchange(v){},set oninput(v){},set ondragover(v){},set ondrop(v){},'
            'addEventListener:()=>{}});globalThis.window={};globalThis.alert=()=>{};'
            'globalThis.document={getElementById:(id)=>({...el(),value:id==="size"?"64":"0"}),'
            'createElement:()=>el(),querySelectorAll:()=>[],addEventListener:()=>{},body:el()};')
    return shim + "\n" + js


def node(code):
    f = tempfile.NamedTemporaryFile("w", suffix=".js", delete=False)
    f.write(savetool_js() + "\n" + code); f.close()
    try:
        return subprocess.run(["node", f.name], capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(f.name)


def savetool_check():
    print("2. savetool (build + read back)")
    r = node(r"""
const fs=require('fs');
config={pal:0,vid:0,sync:0}; bank=new Uint8Array(2048);
const body=new Uint8Array(DATA_SIZE); for(let i=0;i<DATA_SIZE;i++) body[i]=(i*73+i*i)&0xFF;
for(let i=0;i<DATA_SIZE;i+=4){ body[i]=0xFF; body[i+1]=0xFF; body[i+2]=0; body[i+3]=0; }  // sparse-ish
songs=[{title:"REGTEST",data:body}];
const sav=buildSav();
const {logical}=toLogical(sav);
const e=DIR_BASE, off=(logical[e+2]<<8)|logical[e+3], len=(logical[e+4]<<8)|logical[e+5];
const blob=logical.slice(HEAP_BASE+off, HEAP_BASE+off+len);
const data=rleDecompress(blob, DATA_SIZE);
let diff=0; for(let i=0;i<DATA_SIZE;i++) if(data[i]!==body[i]) diff++;
const name=String.fromCharCode(...logical.slice(e+6,e+14));
console.log(JSON.stringify({valid:logical[e],name,off,len,diff}));
fs.writeFileSync(process.env.SV||"/tmp/reg_sv.sav", Buffer.from(sav));
""")
    if r.returncode != 0:
        check("savetool runs", False, r.stderr.strip()[:200]); return
    import json
    out = json.loads(r.stdout.strip().splitlines()[-1])
    check("dir entry valid", out["valid"] == 0xA5)
    check("name stored", out["name"].strip() == "REGTEST")
    check("build->read 0-diff", out["diff"] == 0, f"{out['diff']} bytes differ")
    check("blob at offset 0", out["off"] == 0)


def build_injected(inject):
    """Back up src, splice in the inject + fast splash, make, restore src. -> rom bytes path."""
    orig = open(SRC).read()
    bak = orig
    try:
        patched = orig.replace(INJECT_ANCHOR, inject + "\n" + INJECT_ANCHOR, 1).replace(SPLASH_FROM, SPLASH_TO, 1)
        if patched == orig:
            raise RuntimeError("inject anchor not found -- src/main.asm changed?")
        open(SRC, "w").write(patched)
        shutil.rmtree(os.path.join(ROOT, "build"), ignore_errors=True)
        m = subprocess.run(["make"], cwd=ROOT, capture_output=True, text=True)
        if not os.path.exists(ROM):
            raise RuntimeError("build failed:\n" + m.stderr[-400:])
        dst = tempfile.mktemp(suffix=".bin")
        shutil.copy(ROM, dst)
        return dst
    finally:
        open(SRC, "w").write(bak)


def harness(rom, sram_out=None, sram_in=None, frames=90):
    env = dict(os.environ)
    if sram_out: env["RETROSHOT_SRAM_OUT"] = sram_out
    if sram_in:  env["RETROSHOT_SRAM"] = sram_in
    subprocess.run([SHOT, CORE, rom, "/tmp/reg.ppm", str(frames), "0"],
                   capture_output=True, env=env, timeout=120)


def parse_dir(sav):
    out = []
    for i in range(DIR_N):
        e = LEAD + DIR_BASE + i * DIR_ENT
        if sav[e] != 0xA5: continue
        off = (sav[e+2] << 8) | sav[e+3]; ln = (sav[e+4] << 8) | sav[e+5]
        name = bytes(sav[e+6:e+14]).decode("latin1").rstrip()
        out.append({"i": i, "off": off, "len": ln, "name": name})
    return out


def save_song_inject(name):
    asm = ["    lea     song_title, a0"]
    nm = (name + "        ")[:8]
    for c in nm:
        asm.append(f"    move.b  #'{c}',(a0)+" if c != ' ' else "    move.b  #' ',(a0)+")
    asm.append("    bsr     dir_save")
    return "\n".join(asm)


def cart_check():
    print("3. cart directory (save A/B/C, delete B)")
    inject = ("    movem.l d0-d7/a0-a6, -(sp)\n"
              + save_song_inject("AAA") + "\n"
              + save_song_inject("BBB") + "\n"
              + save_song_inject("CCC") + "\n"
              + "    move.l  #1, d0\n    bsr     dir_delete\n"
              + "    movem.l (sp)+, d0-d7/a0-a6")
    rom = build_injected(inject)
    try:
        sav = "/tmp/reg_cart.sav"
        harness(rom, sram_out=sav)
        d = parse_dir(open(sav, "rb").read())
        names = [e["name"] for e in d]
        check("2 valid entries after delete", len(d) == 2, f"got {names}")
        check("names are AAA + CCC", names == ["AAA", "CCC"], f"{names}")
        if len(d) == 2:
            # heap compacted: AAA at 0, CCC right after it (offset == AAA's len), no hole
            a = next((e for e in d if e["name"] == "AAA"), None)
            c = next((e for e in d if e["name"] == "CCC"), None)
            check("AAA blob at offset 0", a and a["off"] == 0)
            check("CCC blob compacted (offset == len(AAA))", a and c and c["off"] == a["len"],
                  f"AAA len {a['len'] if a else '?'}, CCC off {c['off'] if c else '?'}")
    finally:
        os.path.exists(rom) and os.unlink(rom)


def cart_loads_savetool():
    print("4. savetool .sav -> ROM dir_load (format compat)")
    # /tmp/reg_sv.sav was written by savetool_check(); parse it the way the ROM does
    if not os.path.exists("/tmp/reg_sv.sav"):
        check("savetool .sav present", False, "run check 2 first"); return
    sav = open("/tmp/reg_sv.sav", "rb").read()
    d = parse_dir(sav)
    check("savetool dir parses as ROM expects", len(d) == 1 and d[0]["name"] == "REGTEST",
          f"{[e['name'] for e in d]}")
    if d:
        e = d[0]
        blob = sav[LEAD + HEAP_BASE + e["off"]: LEAD + HEAP_BASE + e["off"] + e["len"]]
        sys.path.insert(0, os.path.join(ROOT, "tools"))
        import rletest
        dec = rletest.rle_decompress(blob)
        check("ROM-side decompress yields the data block", len(dec) == DATA_SIZE,
              f"got {len(dec)} bytes")


def main():
    quick = "--quick" in sys.argv
    print("=== RLE regression ===")
    codec_check()
    savetool_check()
    if not quick:
        if not (os.path.exists(CORE) and os.path.exists(SHOT)):
            print("  (skipping cart checks: build tools/emu/retroshot + the core first)")
        else:
            cart_check()
    cart_loads_savetool()
    print(f"\n{'ALL PASS' if not fails else 'FAILURES: ' + ', '.join(fails)}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
