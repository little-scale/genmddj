#!/usr/bin/env python3
"""genmddj headless regression tests.

Builds instrumented test ROMs (a patched COPY of src/main.asm -- the working tree is
never touched), runs them on the retroshot libretro harness, and asserts against the
engine's diagnostic counters read back from a 68k work-RAM dump.

    python3 tools/test/runtests.py            # run everything
    python3 tools/test/runtests.py dac_rate   # run one test

Requires tools/emu/retroshot + tools/emu/genesis_plus_gx_libretro.dylib (gitignored --
fetched/built separately; tests SKIP with a notice when absent).

Probe conventions (see the dac-feed / scb-stream memories + driver.asm diag cells):
  Z80 $1F78 CT_PSG   -- PSG bytes written (byte, wraps)
  Z80 $1F79 CT_YM    -- YM triples written (byte, wraps)
  Z80 $1F7A CT_FEED  -- DAC bytes fed (byte, wraps; per-frame diffs are mod-256)
  68k $FFD500        -- run-once guard for boot injects
  68k $FFD520+       -- 64-entry per-frame log ring (word), index = g_ticks & 63
"""
import os, subprocess, sys, struct

ROOT   = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
BUILD  = os.path.join(ROOT, 'build')
TDIR   = os.path.join(BUILD, 'test')
EMU    = os.path.join(ROOT, 'tools', 'emu', 'retroshot')
CORE   = os.path.join(ROOT, 'tools', 'emu', 'genesis_plus_gx_libretro.dylib')

ANCHOR   = '    move.b  #1, need_clear               ; draw header/name on first frame'
SPLASH   = ('    move.w  #100, splash_ctr', '    move.w  #3, splash_ctr')
GTICKS   = '    addq.w  #1, g_ticks                  ; tick counter (4 hex) at row0 col35'

# ---- shared inject fragments ------------------------------------------------------

# per-frame logger at the g_ticks bump: ring[g_ticks&63] = CT_FEED (lo byte); plus a
# one-shot direct DAC arm (bank 1, ptr $8000, len $7000, 1x) at g_ticks == 60.
FRAME_LOGGER = """    movem.l d0-d1/a1, -(sp)
    move.w  g_ticks, d0
    cmpi.w  #60, d0
    bne.s   .tfarm
    move.w  #$0100, Z80_BUSREQ
.tfw:
    btst    #0, Z80_BUSREQ
    bne.s   .tfw
    move.b  #1, Z80_RAM+$1FB1
    move.b  #0, Z80_RAM+$1FB2
    move.b  #0, Z80_RAM+$1FB3
    move.b  #$80, Z80_RAM+$1FB4
    move.b  #0, Z80_RAM+$1FB5
    move.b  #$70, Z80_RAM+$1FB6
    move.b  #1, Z80_RAM+$1FB8
    move.b  #0, Z80_RAM+$1FB9
    move.b  #1, Z80_RAM+$1FB0
    move.w  #$0000, Z80_BUSREQ
.tfarm:
    move.w  #$0100, Z80_BUSREQ
.tfl:
    btst    #0, Z80_BUSREQ
    bne.s   .tfl
    moveq   #0, d1
    move.b  Z80_RAM+$1F7A, d1
    move.w  #$0000, Z80_BUSREQ
    move.w  g_ticks, d0
    andi.w  #63, d0
    add.w   d0, d0
    lea     $00FFD520, a1
    move.w  d1, (a1,d0.w)
    movem.l (sp)+, d0-d1/a1
"""

# same logger but recording CT_PSG (lo) | CT_YM (hi) instead, no DAC arm
SCB_LOGGER = """    movem.l d0-d1/a1, -(sp)
    move.w  #$0100, Z80_BUSREQ
.tsw:
    btst    #0, Z80_BUSREQ
    bne.s   .tsw
    moveq   #0, d1
    move.b  Z80_RAM+$1F79, d1
    lsl.w   #8, d1
    move.b  Z80_RAM+$1F78, d1
    move.w  #$0000, Z80_BUSREQ
    move.w  g_ticks, d0
    andi.w  #63, d0
    add.w   d0, d0
    lea     $00FFD520, a1
    move.w  d1, (a1,d0.w)
    movem.l (sp)+, d0-d1/a1
"""

# per-frame CT_FEED logger WITHOUT the direct DAC arm (for tests that trigger via the engine)
FRAME_LOGGER_NOARM = """    movem.l d0-d1/a1, -(sp)
    move.w  #$0100, Z80_BUSREQ
.tnw:
    btst    #0, Z80_BUSREQ
    bne.s   .tnw
    moveq   #0, d1
    move.b  Z80_RAM+$1F7A, d1
    move.w  #$0000, Z80_BUSREQ
    move.w  g_ticks, d0
    andi.w  #63, d0
    add.w   d0, d0
    lea     $00FFD520, a1
    move.w  d1, (a1,d0.w)
    movem.l (sp)+, d0-d1/a1
"""

# stress song (boot inject): F1 = FM note with an R-retrig every 2 ticks (heavy YM
# triples), T1 = TONE with vibrato (per-frame PSG writes); loops forever.
STRESS_SONG = """    tst.b   $00FFD500
    bne     .tstdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #3, $00FF4AA0
    move.b  #15, $00FF4AA8
    move.b  #0, $00FF4AA9
    move.b  #$0F, $00FF4AAA
    move.b  #0, $00FF4AAB
    move.b  #0, $00FF4AAC
    move.b  #0, $00FF4AAD
    move.b  #$44, $00FF4AAE
    move.b  #0, $00FF4AAF
    move.b  #$FF, $00FF4AD0
    move.b  #0, $00FF0100
    move.b  #1, $00FF0106
    move.b  #0, $00FF3A60
    move.b  #0, $00FF3A61
    move.b  #1, $00FF3A80
    move.b  #0, $00FF3A81
    move.b  #45, $00FF0A60
    move.b  #0, $00FF0A61
    move.b  #18, $00FF0A62
    move.b  #$02, $00FF0A63
    move.b  #45, $00FF0AA0
    move.b  #1, $00FF0AA1
    move.b  #0, play_from
    move.b  #0, play_mode
    move.b  #1, playing
    bsr     engine_play_reset
    movem.l (sp)+, d0-d7/a0-a6
.tstdone:
"""

# KIT hit: F6 plays kit0 pad0 once (chain2/phrase2), plus the stress T1 line for ticks.
KIT_SONG = """    tst.b   $00FFD500
    bne     .tkdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #3, $00FF4AA0
    move.b  #15, $00FF4AA8
    move.b  #$0F, $00FF4AAA
    move.b  #$FF, $00FF4AD0
    move.b  #1, $00FF4B20
    move.b  #0, $00FF4B52
    move.b  #0, $00FF4B54
    move.b  #$FF, $00FF4B50
    move.b  #1, $00FF0106
    move.b  #2, $00FF0105
    move.b  #1, $00FF3A80
    move.b  #0, $00FF3A81
    move.b  #2, $00FF3AA0
    move.b  #0, $00FF3AA1
    move.b  #45, $00FF0AA0
    move.b  #1, $00FF0AA1
    move.b  #0, $00FF0AE0
    move.b  #3, $00FF0AE1
    move.b  #0, play_from
    move.b  #0, play_mode
    move.b  #1, playing
    bsr     engine_play_reset
    movem.l (sp)+, d0-d7/a0-a6
.tkdone:
"""

# CONT: the stress song with T1 (track 6) flagged as a carry, and a frame inject that
# plants the carried voices as looping bridges at frame 30 (no real load -- proves the
# bridge mechanism: snapshot -> plant, carried voice keeps sounding from its private
# buffer + reserved-slot instrument, non-carried voices silenced). See CONT.md.
CONT_SONG = STRESS_SONG.replace('.tstdone:', '    move.w  #$0040, cont_mask\n.tstdone:')
CONT_FIRE = """    move.w  g_ticks, d0
    cmpi.w  #30, d0
    bne.s   .cfskip
    bsr     cont_snapshot_all
    bsr     cont_plant_all
.cfskip:
"""

# arm a beat-quantized swap at frame 5 (fires later, on the carried voice's downbeat)
CONT_ARM = """    move.w  g_ticks, d0
    cmpi.w  #5, d0
    bne.s   .caskip
    moveq   #1, d0
    bsr     cont_load_arm
.caskip:
"""

# ---- build/run machinery ----------------------------------------------------------

def build_rom(name, boot_inject=None, frame_inject=None):
    """Patch a copy of main.asm, assemble it, fix the header. Returns the ROM path."""
    os.makedirs(TDIR, exist_ok=True)
    src = open(os.path.join(ROOT, 'src', 'main.asm')).read()
    assert src.count(ANCHOR) == 1, 'boot anchor drifted -- update runtests.py'
    assert src.count(GTICKS) == 1, 'g_ticks anchor drifted -- update runtests.py'
    if boot_inject:
        src = src.replace(ANCHOR, boot_inject + ANCHOR, 1)
    if frame_inject:
        src = src.replace(GTICKS, GTICKS + '\n' + frame_inject, 1)
    src = src.replace(*SPLASH)
    asm = os.path.join(TDIR, name + '.asm')
    raw = os.path.join(TDIR, name + '.raw')
    rom = os.path.join(TDIR, name + '.bin')
    open(asm, 'w').write(src)
    subprocess.run(['vasmm68k_mot', '-Fbin', '-spaces', '-quiet', '-m68000',
                    '-o', raw, asm], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(['python3', 'tools/fixheader.py', raw, rom],
                   cwd=ROOT, check=True, capture_output=True)
    return rom

def run_rom(rom, frames, buttons='0'):
    """Run the ROM; return the un-byteswapped 68k work-RAM image (offset = addr-$FF0000)."""
    dump = rom + '.ram'
    env = dict(os.environ, RETROSHOT_RAM_OUT=dump)
    subprocess.run([EMU, CORE, rom, rom + '.ppm', str(frames), buttons],
                   env=env, check=True, capture_output=True)
    d = open(dump, 'rb').read()
    ds = bytearray(len(d))
    ds[0::2] = d[1::2]
    ds[1::2] = d[0::2]
    return ds

def ring(ram):
    return [struct.unpack('>H', ram[0xD520 + i*2 : 0xD522 + i*2])[0] for i in range(64)]

# ---- the tests --------------------------------------------------------------------

def t_dac_rate():
    """PCM feed keeps pace with Timer A (regression floor: the known GPGX baseline)."""
    rom = build_rom('dac_rate', boot_inject=None, frame_inject=FRAME_LOGGER)
    ram = run_rom(rom, 220)
    r = ring(ram)
    diffs = [(r[(i+1) % 64] - r[i]) & 0xFF for i in range(64)]
    act = sorted(x for x in diffs if 100 < x < 250)
    assert len(act) >= 20, 'sample never fed (%r)' % diffs
    med = act[len(act)//2]
    eff = med * 59.92
    # nominal 10653; GPGX's timer flag-clear race reads ~171/frame (96.2%). Regression
    # floor 165 (=94.5%); ceiling 185 catches a mis-set Timer A / bake mismatch.
    assert 165 <= med <= 185, 'feed %d/frame (%.0f Hz) outside [165,185]' % (med, eff)
    return 'feed %.0f Hz (%d/frame, GPGX baseline 171)' % (eff, med)

def t_kit_endstop():
    """A real KIT drum feeds and STOPS at sample end (no runaway / no silence)."""
    rom = build_rom('kit_endstop', boot_inject=KIT_SONG, frame_inject=FRAME_LOGGER_NOARM)
    ram = run_rom(rom, 220)
    r = ring(ram)
    diffs = [(r[(i+1) % 64] - r[i]) & 0xFF for i in range(64)]
    moving = sum(1 for x in diffs if 50 < x < 250)
    still  = sum(1 for x in diffs if x == 0)
    assert moving >= 5, 'drum never fed (%r)' % diffs
    assert still >= 5, 'feed never stopped -- runaway sample? (%r)' % diffs
    return 'drum fed (%d moving frames) and stopped (%d still)' % (moving, still)

def t_scb_delivery():
    """Under the stress song, PSG bytes and YM triples flow every tick (sliced executor)."""
    rom = build_rom('scb_delivery', boot_inject=STRESS_SONG, frame_inject=SCB_LOGGER)
    ram = run_rom(rom, 160)
    r = ring(ram)
    psg = [x & 0xFF for x in r]
    ym  = [x >> 8 for x in r]
    dpsg = sum(1 for i in range(64) if (psg[(i+1) % 64] - psg[i]) & 0xFF not in (0,))
    dym  = sum(1 for i in range(64) if (ym[(i+1) % 64]  - ym[i])  & 0xFF not in (0,))
    assert dpsg >= 20, 'PSG writes not flowing (%d moving frames)' % dpsg
    assert dym  >= 20, 'YM triples not flowing (%d moving frames)' % dym
    return 'PSG %d + YM %d moving frames of 64' % (dpsg, dym)

def t_cont_bridge():
    """CONT: a carried voice, planted as a bridge, keeps sounding from its private buffer;
    non-carried voices are silenced (the core song-to-song continuity mechanism)."""
    rom = build_rom('cont_bridge', boot_inject=CONT_SONG, frame_inject=CONT_FIRE + SCB_LOGGER)
    ram = run_rom(rom, 64)
    ch = lambda t: 0xE000 + t*40
    t6c   = ram[ch(6)+20]                                   # T1 c_chain
    t6ph  = int.from_bytes(ram[ch(6)+16:ch(6)+20], 'big')   # T1 c_phrase
    t6ins = ram[ch(6)+33]                                   # T1 c_instr
    t6vol = ram[ch(6)+4]                                    # T1 c_vol
    t0c, t0ky, t0vol = ram[ch(0)+20], ram[ch(0)+30], ram[ch(0)+4]
    assert t6c == 0xFE, 'bridge sentinel not set (c_chain=$%02X)' % t6c
    assert 0xFFD790 <= t6ph < 0xFFD7D0, 'bridge c_phrase not in carry_buf ($%08X)' % t6ph
    assert t6ins == 31, 'bridge c_instr not the reserved slot (%d)' % t6ins
    assert t6vol > 0, 'bridge is silent (c_vol=%d)' % t6vol
    assert t0c == 0xFF and t0ky == 0 and t0vol == 0, \
        'non-carried F1 not silenced (chain=$%02X keyon=%d vol=%d)' % (t0c, t0ky, t0vol)
    return 'T1 bridged (c_vol=%d, private phrase), F1 silenced' % t6vol

def t_cont_quantize():
    """CONT: an armed swap HOLDS until the carried voice's phrase downbeat, then fires
    (beat-quantized) -- not the instant LOAD is pressed."""
    rom = build_rom('cont_quantize', boot_inject=CONT_SONG, frame_inject=CONT_ARM)
    held = run_rom(rom, 60)
    assert held[0xD763] == 1, 'CONT fired before a downbeat (cont_pending cleared early)'
    fired = run_rom(rom, 220)
    assert fired[0xD763] == 0, 'CONT never fired (still armed at frame 220)'
    assert fired[0xE104] == 0xFE, 'fired but did not plant the bridge (c_chain=$%02X)' % fired[0xE104]
    return 'armed, held past frame 60, fired on a later downbeat'

def t_boot_smoke():
    """The ROM boots to a rendered SONG screen (non-blank display, engine idle-clean)."""
    rom = build_rom('boot_smoke')
    ram = run_rom(rom, 150)
    ppm = open(rom + '.ppm', 'rb').read()
    body = ppm[ppm.index(b'255\n') + 4:]
    lit = sum(1 for b in body[::97] if b > 32)
    assert lit > 50, 'screen looks blank (%d lit probes)' % lit
    cur_screen = ram[0xE20B]
    assert cur_screen == 2, 'boot screen %d != SONG' % cur_screen
    return 'boot renders SONG (%d lit probes)' % lit

TESTS = [
    ('boot_smoke',   t_boot_smoke),
    ('dac_rate',     t_dac_rate),
    ('kit_endstop',  t_kit_endstop),
    ('scb_delivery', t_scb_delivery),
    ('cont_bridge',  t_cont_bridge),
    ('cont_quantize', t_cont_quantize),
]

def main():
    if not (os.path.exists(EMU) and os.path.exists(CORE)):
        print('SKIP: tools/emu/retroshot + genesis_plus_gx core not present (fetched separately)')
        return 0
    want = sys.argv[1:] or [n for n, _ in TESTS]
    fails = 0
    for name, fn in TESTS:
        if name not in want:
            continue
        try:
            msg = fn()
            print('PASS %-13s %s' % (name, msg))
        except AssertionError as e:
            print('FAIL %-13s %s' % (name, e))
            fails += 1
        except subprocess.CalledProcessError as e:
            print('FAIL %-13s build/run error: %s' % (name, (e.stderr or b'')[:200]))
            fails += 1
    return 1 if fails else 0

if __name__ == '__main__':
    sys.exit(main())
