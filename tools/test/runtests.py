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
import math, os, subprocess, sys, struct, wave

ROOT   = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
BUILD  = os.path.join(ROOT, 'build')
TDIR   = os.path.join(BUILD, 'test')
EMU    = os.path.join(ROOT, 'tools', 'emu', 'retroshot')
CORE   = os.path.join(ROOT, 'tools', 'emu', 'genesis_plus_gx_libretro.dylib')

ANCHOR   = '    move.b  #1, need_clear               ; draw header/name on first frame'
SPLASH   = ('    move.w  #100, splash_ctr', '    move.w  #3, splash_ctr')
GTICKS   = '    addq.w  #1, g_ticks                  ; internal frame clock (not displayed)'

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

# per-frame KIT retrigger logger: high byte = Z80 DAC trigger sequence, low byte =
# F6's accumulated R-command attenuation. A healthy KIT retrigger advances both.
DAC_TRIGGER_LOGGER = """    movem.l d0-d1/a1, -(sp)
    move.w  #$0100, Z80_BUSREQ
.tdtw:
    btst    #0, Z80_BUSREQ
    bne.s   .tdtw
    moveq   #0, d1
    move.b  Z80_RAM+$1FB0, d1
    lsl.w   #8, d1
    move.w  #$0000, Z80_BUSREQ
    move.b  c_rtdrop+5, d1
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
    move.b  #0, $00FF4B53
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

# Same real F6 KIT hit, with R12: halve one gain-pool step and restart every 2 ticks.
KIT_RETRIG_SONG = KIT_SONG.replace(
    "    move.b  #3, $00FF0AE1\n",
    "    move.b  #3, $00FF0AE1\n"
    "    move.b  #18, $00FF0AE2\n"
    "    move.b  #$12, $00FF0AE3\n")

# Directly trigger a long KIT pad once so audio amplitude can be compared without any
# FM/PSG voices contaminating the capture. The test replaces the i_gain immediate.
KIT_GAIN_ARM = """    tst.b   $00FFD500
    bne     .tkgdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    lea     instrum, a1
    move.b  #1, (i_type,a1)
    move.b  #0, (i_kit,a1)
    move.b  #0, (i_gain,a1)
    move.b  #0, (i_rate,a1)
    lea     ch_state, a6
    clr.b   c_track(a6)
    move.b  #$FF, c_srate
    moveq   #0, d0
    moveq   #13, d1
    bsr     dac_play
    movem.l (sp)+, d0-d7/a0-a6
.tkgdone:
"""

KIT_NAV = """    tst.b   $00FFD500
    bne     .tkndone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #SCR_INSTR, cur_screen
    clr.b   cur_instr
    lea     instrum, a1
    move.b  #1, (i_type,a1)
    move.b  #2, cur_row
    clr.b   cur_col
    moveq   #2, d2
    bsr     move_cursor
    move.b  cur_row, $00FFD501
    bsr     move_cursor
    move.b  cur_row, $00FFD502
    bsr     move_cursor
    move.b  cur_row, $00FFD503
    bsr     move_cursor
    move.b  cur_row, $00FFD504
    moveq   #1, d2
    bsr     move_cursor
    move.b  cur_row, $00FFD505
    move.b  #3, cur_row
    clr.b   (i_gain,a1)
    moveq   #4, d2
    bsr     edit_psg
    move.b  instrum+i_gain, $00FFD506
    moveq   #8, d2
    bsr     edit_psg
    move.b  instrum+i_gain, $00FFD507
    move.b  #5, instrum+i_gain
    moveq   #4, d2
    bsr     edit_psg
    move.b  instrum+i_gain, $00FFD508
    moveq   #8, d2
    bsr     edit_psg
    move.b  instrum+i_gain, $00FFD509
    clr.b   instrum+i_gain
    moveq   #1, d2
    bsr     edit_psg
    move.b  instrum+i_gain, $00FFD50A
    moveq   #2, d2
    bsr     edit_psg
    move.b  instrum+i_gain, $00FFD50B
    move.b  #1, cur_row
    move.b  #5, cur_col
    moveq   #2, d2
    bsr     move_cursor
    move.b  cur_row, $00FFD50C
    move.b  cur_col, $00FFD50D
    movem.l (sp)+, d0-d7/a0-a6
.tkndone:
"""

# CONT: the stress song with T1 (track 6) flagged as a carry, and a frame inject that
# plants the carried voices as looping bridges at frame 30 (no real load -- proves the
# bridge mechanism: snapshot -> plant, carried voice keeps sounding from its private
# buffer + reserved-slot instrument, non-carried voices silenced). See CONT.md.
CONT_SONG = STRESS_SONG.replace('.tstdone:', '    move.w  #$0040, cont_mask\n.tstdone:')
CONT_LOAD_SONG = CONT_SONG.replace(
    '    move.b  #1, playing',
    '    bsr     dir_save\n    move.b  #1, playing', 1)
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
    moveq   #0, d0
    bsr     cont_load_arm
.caskip:
"""

# Deterministic LIVE->LIVE handover: track 0 carries, track 1 is deliberately
# stale, target slots 30/31 are referenced, and slot 29 is the expected borrow.
CONT_LIVE_HANDOVER = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #1, proj_mode
    move.b  #0, ch_state+c_track
    move.b  #0, ch_state+c_instr
    move.b  #0, ch_state+c_chain
    move.b  #0, ch_state+c_songpos
    move.b  #15, ch_state+c_row
    move.l  #phrases, ch_state+c_phrase
    move.b  #6, instrum+i_algo
    move.b  #$30, phrases
    move.b  #0, phrases+1
    move.w  #1, cont_mask
    bsr     cont_snapshot_all
    move.b  #$31, phrases
    move.b  #31, phrases+1
    move.b  #$32, phrases+4
    move.b  #30, phrases+5
    move.b  #0, song
    move.b  #1, song+NCH
    move.b  #0, chains
    move.b  #$FF, chains+2
    move.b  #1, chains+CHAIN_SIZE
    move.b  #$FF, chains+CHAIN_SIZE+2
    move.b  #5, instrum+(29*INSTR_SIZE)+i_algo
    move.b  #3, instrum+(30*INSTR_SIZE)+i_algo
    move.b  #4, instrum+(31*INSTR_SIZE)+i_algo
    move.b  #1, ch_state+CHSIZE+c_track
    move.b  #1, ch_state+CHSIZE+c_chain
    move.b  #1, live_on+1
    move.b  #7, live_q+1
    move.b  #2, live_when+1
    bsr     cont_plant_all
    move.b  ch_state+c_instr, $00FFD800
    move.b  instrum+(29*INSTR_SIZE)+i_algo, $00FFD801
    move.b  instrum+(30*INSTR_SIZE)+i_algo, $00FFD802
    move.b  instrum+(31*INSTR_SIZE)+i_algo, $00FFD803
    move.b  live_on+1, $00FFD804
    move.b  live_when+1, $00FFD805
    move.b  ch_state+CHSIZE+c_chain, $00FFD806
    move.b  live_on, $00FFD807
    lea     ch_state, a6
    bsr     advance_ch
    move.b  ch_state+c_chain, $00FFD808
    move.b  carry_slot, $00FFD809
    move.b  live_when, $00FFD80A
    move.b  ch_state+c_instr, $00FFD80B
    clr.b   $00FFD80C
    cmpi.l  #carry_buf, ch_state+c_phrase
    bne.s   .tlh_ptr
    move.b  #$FF, $00FFD80C
.tlh_ptr:
    moveq   #0, d1
    moveq   #0, d2                         ; same row number as stale old c_songpos
    bsr     live_queue_track               ; must replace the bridge, not queue a stop
    move.b  live_when, $00FFD80D
    move.b  #15, ch_state+c_row
    lea     ch_state, a6
    bsr     advance_ch
    move.b  ch_state+c_chain, $00FFD80E
    move.b  ch_state+c_cstep, $00FFD80F
    move.b  live_when, $00FFD810
    move.b  carry_slot, $00FFD811
    move.b  instrum+(29*INSTR_SIZE)+i_algo, $00FFD812
    clr.b   $00FFD813
    cmpi.l  #phrases, ch_state+c_phrase
    bne.s   .tlh_target_ptr
    move.b  #$FF, $00FFD813
.tlh_target_ptr:
    movem.l (sp)+, d0-d7/a0-a6
"""

# Empty target: a carried private phrase keeps looping until the performer
# explicitly launches a populated SONG cell; an empty target never stops it.
CONT_EMPTY_TARGET = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #1, proj_mode
    move.b  #0, ch_state+c_track
    move.b  #0, ch_state+c_instr
    move.b  #0, ch_state+c_chain
    move.b  #0, ch_state+c_songpos
    move.b  #15, ch_state+c_row
    move.l  #phrases, ch_state+c_phrase
    move.b  #6, instrum+i_algo
    move.b  #$30, phrases
    move.b  #0, phrases+1
    move.w  #1, cont_mask
    bsr     cont_snapshot_all
    move.b  #$FF, phrases
    move.b  #$FF, phrases+1
    move.b  #4, instrum+(31*INSTR_SIZE)+i_algo
    bsr     cont_plant_all
    lea     ch_state, a6
    bsr     advance_ch
    move.b  ch_state+c_chain, $00FFD800
    move.b  ch_state+c_row, $00FFD801
    move.b  carry_slot, $00FFD802
    move.b  live_on, $00FFD803
    move.b  instrum+(31*INSTR_SIZE)+i_algo, $00FFD804
    clr.b   $00FFD805
    cmpi.l  #carry_buf, ch_state+c_phrase
    bne.s   .tet_ptr
    move.b  #$FF, $00FFD805
.tet_ptr:
    move.b  carry_instr+i_algo, $00FFD806
    movem.l (sp)+, d0-d7/a0-a6
"""

# A target that references every slot must reject the bridge cleanly instead
# of overwriting any target instrument.
CONT_NO_FREE_SLOT = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #1, proj_mode
    move.b  #0, ch_state+c_track
    move.b  #0, ch_state+c_instr
    move.b  #0, ch_state+c_chain
    move.b  #15, ch_state+c_row
    move.l  #phrases, ch_state+c_phrase
    move.b  #6, instrum+i_algo
    move.b  #$30, phrases
    move.b  #0, phrases+1
    move.w  #1, cont_mask
    bsr     cont_snapshot_all
    lea     phrases+1, a0
    moveq   #0, d0
.tnf_fill:
    move.b  d0, (a0)
    addq.l  #4, a0
    addq.b  #1, d0
    cmpi.b  #NINSTR, d0
    blo.s   .tnf_fill
    move.b  #4, instrum+(31*INSTR_SIZE)+i_algo
    bsr     cont_plant_all
    move.b  ch_state+c_chain, $00FFD800
    move.b  carry_slot, $00FFD801
    move.b  live_on, $00FFD802
    move.b  instrum+(31*INSTR_SIZE)+i_algo, $00FFD803
    movem.l (sp)+, d0-d7/a0-a6
"""

# A bridge phrase may change instrument on any row. Preserve those references as
# distinct borrowed target slots, then restore the displaced target records together
# when the last bridge retires.
CONT_MULTI_INSTR = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #1, proj_mode
    move.b  #0, ch_state+c_track
    move.b  #2, ch_state+c_instr
    move.b  #0, ch_state+c_chain
    move.b  #15, ch_state+c_row
    move.b  #1, ch_state+c_type
    move.l  #phrases, ch_state+c_phrase
    move.b  #6, instrum+(2*INSTR_SIZE)+i_algo
    move.b  #7, instrum+(3*INSTR_SIZE)+i_algo
    move.b  #$30, phrases
    move.b  #2, phrases+1
    move.b  #$31, phrases+4
    move.b  #3, phrases+5
    move.w  #1, cont_mask
    bsr     cont_snapshot_all
    move.b  #$32, phrases
    move.b  #31, phrases+1
    move.b  #$33, phrases+4
    move.b  #30, phrases+5
    move.b  #4, instrum+(29*INSTR_SIZE)+i_algo
    move.b  #5, instrum+(28*INSTR_SIZE)+i_algo
    bsr     cont_plant_all
    move.b  carry_buf+1, $00FFD501
    move.b  carry_buf+5, $00FFD502
    move.b  ch_state+c_instr, $00FFD503
    move.b  instrum+(29*INSTR_SIZE)+i_algo, $00FFD504
    move.b  instrum+(28*INSTR_SIZE)+i_algo, $00FFD505
    move.b  ch_state+c_chain, $00FFD506
    move.b  cont_active, $00FFD507
    lea     ch_state, a6
    bsr     cont_restore_track
    move.b  instrum+(29*INSTR_SIZE)+i_algo, $00FFD508
    move.b  instrum+(28*INSTR_SIZE)+i_algo, $00FFD509
    move.b  cont_active, $00FFD50A
    movem.l (sp)+, d0-d7/a0-a6
"""

# During an overlap, source globals remain authoritative, source software LFOs
# run only on bridge channels, and target echo is dormant. The target state returns
# atomically when the final bridge retires.
CONT_GLOBAL_ISOLATION = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #1, proj_mode
    move.b  #0, ch_state+c_track
    move.b  #0, ch_state+c_instr
    move.b  #0, ch_state+c_chain
    move.b  #15, ch_state+c_row
    move.b  #1, ch_state+c_type
    move.l  #phrases, ch_state+c_phrase
    move.b  #$30, phrases
    move.b  #0, phrases+1
    move.b  #1, lfo_cfg+LF_FLAGS
    move.b  #0, lfo_cfg+LF_CHAN
    move.b  #13, lfo_cfg+LF_PARM
    move.b  #16, lfo_cfg+LF_RATE
    move.b  #3, lfo_cfg+LF_DEPTH
    move.b  #4, lfo_cfg+LF_POFF
    move.b  #1, lfo_cfg+LF_SIZE+LF_FLAGS
    move.b  #1, lfo_cfg+LF_SIZE+LF_CHAN
    move.b  #13, lfo_cfg+LF_SIZE+LF_PARM
    move.b  #32, lfo_cfg+LF_SIZE+LF_RATE
    move.b  #3, lfo_cfg+LF_SIZE+LF_DEPTH
    move.b  #4, lfo_cfg+LF_SIZE+LF_POFF
    move.w  #$1000, lfo_phase
    move.w  #$2000, lfo_phase+2
    move.b  #7, g_lfo
    move.b  #$FD, proj_tsp
    move.b  #5, scale_key
    move.b  #2, scale_type
    move.w  #1, cont_mask
    bsr     cont_snapshot_all
    move.b  #$31, phrases
    move.b  #31, phrases+1
    move.b  #1, SAVE_BASE+GLOB_LFO_OFS+LF_FLAGS
    move.b  #1, SAVE_BASE+GLOB_LFO_OFS+LF_CHAN
    move.b  #12, SAVE_BASE+GLOB_LFO_OFS+LF_PARM
    move.b  #$55, SAVE_BASE+GLOB_LFO_OFS+LF_RATE
    move.b  #$66, SAVE_BASE+GLOB_LFO_OFS+LF_DEPTH
    move.b  #$77, SAVE_BASE+GLOB_LFO_OFS+LF_POFF
    move.b  #4, SAVE_BASE+0
    move.b  #2, SAVE_BASE+3
    move.b  #8, SAVE_BASE+10
    move.b  #3, SAVE_BASE+11
    move.b  #2, echo_mode
    move.b  #5, echo_head
    move.b  #$7A, echo_ring
    bsr     cont_plant_all
    move.b  cont_active, $00FFD520
    move.b  g_lfo, $00FFD521
    move.b  proj_tsp, $00FFD522
    move.b  scale_key, $00FFD523
    move.b  scale_type, $00FFD524
    move.b  echo_head, $00FFD525
    move.b  echo_ring, $00FFD526
    move.b  lfo_cfg+LF_CHAN, $00FFD527
    move.w  lfo_phase, $00FFD528
    move.w  lfo_phase+2, $00FFD52A
    move.b  #1, ch_state+CHSIZE+c_track
    move.b  #1, ch_state+CHSIZE+c_type
    move.b  #31, ch_state+CHSIZE+c_instr
    move.b  #0, ch_state+CHSIZE+c_chain
    lea     $00FFD580, a5
    moveq   #0, d5
    bsr     fmlfo_tick
    move.w  lfo_phase, $00FFD52C
    move.w  lfo_phase+2, $00FFD52E
    lea     ch_state+CHSIZE, a6
    bsr     is_echo_target
    move.b  d0, $00FFD530
    lea     ch_state, a6
    bsr     cont_restore_track
    move.b  cont_active, $00FFD531
    move.b  g_lfo, $00FFD532
    move.b  proj_tsp, $00FFD533
    move.b  scale_key, $00FFD534
    move.b  scale_type, $00FFD535
    move.b  lfo_cfg+LF_CHAN, $00FFD536
    move.b  lfo_cfg+LF_PARM, $00FFD537
    move.b  lfo_cfg+LF_RATE, $00FFD538
    move.w  lfo_phase, $00FFD53A
    lea     ch_state+CHSIZE, a6
    bsr     is_echo_target
    move.b  d0, $00FFD53C
    movem.l (sp)+, d0-d7/a0-a6
"""

# Reproduce a real UI sequence: audition a chain, stop, enter LIVE, then launch
# row 0 of a two-row contiguous block. The stale chain-solo mode must not make
# LIVE loop chain 0 forever.
LIVE_CONTIGUOUS = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #0, song
    move.b  #1, song+NCH
    move.b  #0, chains
    move.b  #$FF, chains+2
    move.b  #1, chains+CHAIN_SIZE
    move.b  #$FF, chains+CHAIN_SIZE+2
    clr.b   playing
    clr.b   proj_mode
    move.b  #SCR_CHAIN, cur_screen
    clr.b   cur_chan
    clr.b   cur_chain
    clr.b   cur_row
    bsr     play_context
    bsr     play_context
    move.b  #1, proj_mode
    move.b  #SCR_SONG, cur_screen
    clr.b   cur_col
    clr.b   cur_row
    clr.b   song_page
    bsr     live_launch_track
    move.b  play_mode, $00FFD800
    lea     ch_state, a6
    bsr     advance_ch
    move.b  #15, c_row(a6)
    bsr     advance_ch
    move.b  c_songpos(a6), $00FFD801
    move.b  c_chain(a6), $00FFD802
    move.b  c_cstep(a6), $00FFD803
    movem.l (sp)+, d0-d7/a0-a6
"""

# A completely full 16-step chain has no $FF terminator. Arrangement playback
# must treat the 15->0 step wrap as the chain end; chain-solo must still loop it.
LIVE_FULL_CHAIN = """    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #0, song
    move.b  #1, song+NCH
    lea     chains, a0
    moveq   #15, d0
.lfc_fill:
    move.b  #0, (a0)+
    clr.b   (a0)+
    dbra    d0, .lfc_fill
    move.b  #1, chains+CHAIN_SIZE
    move.b  #$FF, chains+CHAIN_SIZE+2
    move.b  #1, proj_mode
    clr.b   play_mode
    moveq   #0, d1
    moveq   #0, d2
    bsr     live_setup_chan
    lea     ch_state, a6
    move.b  #15, c_cstep(a6)
    move.b  #15, c_row(a6)
    bsr     advance_ch
    move.b  c_songpos(a6), $00FFD810
    move.b  c_chain(a6), $00FFD811
    move.b  c_cstep(a6), $00FFD812
    move.b  #1, play_mode
    move.b  #0, c_songpos(a6)
    move.b  #0, c_chain(a6)
    move.b  #15, c_cstep(a6)
    move.b  #15, c_row(a6)
    bsr     advance_ch
    move.b  c_songpos(a6), $00FFD813
    move.b  c_chain(a6), $00FFD814
    move.b  c_cstep(a6), $00FFD815
    clr.b   proj_mode
    clr.b   play_mode
    move.b  #0, c_songpos(a6)
    move.b  #0, c_chain(a6)
    move.b  #15, c_cstep(a6)
    move.b  #15, c_row(a6)
    bsr     advance_ch
    move.b  c_songpos(a6), $00FFD816
    move.b  c_chain(a6), $00FFD817
    move.b  c_cstep(a6), $00FFD818
    movem.l (sp)+, d0-d7/a0-a6
"""

SAVE_ROUNDTRIP = """    tst.b   $00FFD500
    bne.s   .tsrdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #$2A, song
    bsr     dir_save
    move.b  files_error, $00FFD501
    moveq   #0, d0
    bsr     dir_rd
    move.b  dir_ent, $00FFD502
    move.b  #$55, song
    moveq   #0, d0
    bsr     dir_load
    move.b  song, $00FFD503
    move.b  load_ok, $00FFD504
    move.b  files_error, $00FFD505
    movem.l (sp)+, d0-d7/a0-a6
.tsrdone:
"""

LFO_SAVE_STATE = """    tst.b   $00FFDD00
    bne     .tlsdone
    move.b  #1, $00FFDD00
    movem.l d0-d7/a0-a6, -(sp)
    lea     lfo_cfg, a0
    moveq   #(NLFO*LF_SIZE)-1, d0
.tlsclr:
    clr.b   (a0)+
    dbra    d0, .tlsclr
    move.b  #$15, lfo_cfg+LF_FLAGS
    move.b  #5, lfo_cfg+LF_CHAN
    move.b  #34, lfo_cfg+LF_PARM
    move.b  #$A7, lfo_cfg+LF_RATE
    move.b  #$0D, lfo_cfg+LF_DEPTH
    move.b  #$0E, lfo_cfg+LF_POFF
    move.b  #$0B, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_FLAGS
    move.b  #2, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_CHAN
    move.b  #7, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_PARM
    move.b  #$33, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_RATE
    move.b  #4, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_DEPTH
    move.b  #5, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_POFF
    move.w  #$1234, lfo_phase
    move.b  #7, lfo_amp
    bsr     dir_save

    move.b  #$FF, lfo_cfg+LF_FLAGS
    move.b  #$EE, lfo_cfg+LF_CHAN
    move.b  #$DD, lfo_cfg+LF_PARM
    move.b  #$CC, lfo_cfg+LF_RATE
    move.b  #$BB, lfo_cfg+LF_DEPTH
    move.b  #$AA, lfo_cfg+LF_POFF
    move.b  #$FF, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_FLAGS
    move.w  #$5678, lfo_phase
    move.b  #6, lfo_amp
    moveq   #0, d0
    bsr     dir_load
    move.b  lfo_cfg+LF_FLAGS, $00FFDD01
    move.b  lfo_cfg+LF_CHAN, $00FFDD02
    move.b  lfo_cfg+LF_PARM, $00FFDD03
    move.b  lfo_cfg+LF_RATE, $00FFDD04
    move.b  lfo_cfg+LF_DEPTH, $00FFDD05
    move.b  lfo_cfg+LF_POFF, $00FFDD06
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_FLAGS, $00FFDD07
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_CHAN, $00FFDD08
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_PARM, $00FFDD09
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_RATE, $00FFDD0A
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_DEPTH, $00FFDD0B
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_POFF, $00FFDD0C
    move.b  lfo_phase, $00FFDD0D
    move.b  lfo_phase+1, $00FFDD0E
    move.b  lfo_amp, $00FFDD0F
    move.b  load_ok, $00FFDD10

    eori.b  #1, lfo_cfg+LF_RATE
    bsr     check_dirty
    move.b  song_dirty, $00FFDD11

    lea     SAVE_BASE+GLOB_LFO_OFS, a0
    moveq   #(NLFO*LF_SIZE)-1, d0
.tlslegacy:
    clr.b   (a0)+
    dbra    d0, .tlslegacy
    move.b  #$1F, lfo_cfg
    move.b  #$7F, lfo_cfg+((NLFO-1)*LF_SIZE)+LF_RATE
    move.w  #$1357, lfo_phase
    move.b  #5, lfo_amp
    bsr     scatter_globals
    move.b  lfo_cfg, $00FFDD12
    move.b  lfo_cfg+((NLFO-1)*LF_SIZE)+LF_RATE, $00FFDD13
    move.w  lfo_phase, $00FFDD14
    move.b  lfo_amp, $00FFDD16

    lea     SAVE_BASE+GLOB_LFO_OFS, a0
    move.b  #$FF, LF_FLAGS(a0)
    move.b  #$FF, LF_CHAN(a0)
    move.b  #$FF, LF_PARM(a0)
    move.b  #$CC, LF_RATE(a0)
    move.b  #$FE, LF_DEPTH(a0)
    move.b  #$FD, LF_POFF(a0)
    bsr     scatter_globals
    move.b  lfo_cfg+LF_FLAGS, $00FFDD17
    move.b  lfo_cfg+LF_CHAN, $00FFDD18
    move.b  lfo_cfg+LF_PARM, $00FFDD19
    move.b  lfo_cfg+LF_RATE, $00FFDD1A
    move.b  lfo_cfg+LF_DEPTH, $00FFDD1B
    move.b  lfo_cfg+LF_POFF, $00FFDD1C

    move.b  #$1F, lfo_cfg
    move.w  #$2468, lfo_phase
    move.b  #4, lfo_amp
    bsr     clear_song
    move.b  lfo_cfg, $00FFDD1D
    move.w  lfo_phase, $00FFDD1E
    move.b  lfo_amp, $00FFDD20
    movem.l (sp)+, d0-d7/a0-a6
.tlsdone:
"""

LFO_CHAIN_SYNC = """    tst.b   $00FFDD30
    bne     .tlcdone
    move.b  #1, $00FFDD30
    movem.l d0-d7/a0-a6, -(sp)
    lea     lfo_cfg, a0
    moveq   #(NLFO*LF_SIZE)-1, d0
.tlcclr:
    clr.b   (a0)+
    dbra    d0, .tlcclr
    move.b  #((LFRS_CHAIN<<1)|1), lfo_cfg+LF_FLAGS
    move.b  #0, lfo_cfg+LF_CHAN
    move.b  #0, lfo_cfg+LF_PARM
    move.b  #0, lfo_cfg+LF_RATE
    move.b  #0, lfo_cfg+LF_DEPTH
    move.b  #2, lfo_cfg+LF_POFF
    move.b  #1, ch_state+c_type
    move.b  #0, ch_state+c_instr

    move.w  #$5555, lfo_phase
    move.b  #2, ch_state+c_lfosync          ; PHRASE alone must not reset CHAIN sync
    lea     $00FFDD80, a5
    moveq   #0, d5
    bsr     fmlfo_tick
    move.w  lfo_phase, $00FFDD32

    move.w  #$5555, lfo_phase
    move.b  #8, ch_state+c_lfosync          ; CHAIN event resets to PO=2 -> phase $2000
    lea     $00FFDD80, a5
    moveq   #0, d5
    bsr     fmlfo_tick
    move.w  lfo_phase, $00FFDD34

    move.b  #5, cur_col                     ; editor: FREE -> CHAIN -> NOTE -> CHAIN backwards
    move.b  #0, cur_row
    move.b  #((LFRS_FREE<<1)|1), lfo_cfg+LF_FLAGS
    moveq   #1, d2
    bsr     edit_lfo
    move.b  lfo_cfg+LF_FLAGS, $00FFDD36
    bsr     edit_lfo
    move.b  lfo_cfg+LF_FLAGS, $00FFDD37
    moveq   #4, d2
    bsr     edit_lfo
    move.b  lfo_cfg+LF_FLAGS, $00FFDD38

    lea     ch_state, a6                    ; chain step 0 raises the event; interior steps do not
    move.b  #0, c_chain(a6)
    move.b  #$FF, c_cstep(a6)
    move.b  #0, chains
    move.b  #0, chains+1
    move.b  #1, chains+2
    move.b  #0, chains+3
    move.b  #$FF, chains+4
    clr.b   c_lfosync(a6)
    bsr     advance_chain
    move.b  c_lfosync(a6), $00FFDD39
    clr.b   c_lfosync(a6)
    bsr     advance_chain
    move.b  c_lfosync(a6), $00FFDD3A
    move.b  #1, play_mode                  ; end-of-chain loop returns to step 0
    clr.b   c_lfosync(a6)
    bsr     advance_chain
    move.b  c_lfosync(a6), $00FFDD3B
    movem.l (sp)+, d0-d7/a0-a6
.tlcdone:
"""

LOAD_BAD_CHECKSUM = """    tst.b   $00FFD500
    bne.s   .tlbdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #$2A, song
    bsr     dir_save
    move.l  #DIR_BASE+14, d0
    bsr     sram_at
    eori.b  #1, (a1)
    move.b  #0, $A130F1
    move.b  #$66, song
    move.b  #'X', song_title
    moveq   #0, d0
    bsr     dir_load
    move.b  song, $00FFD501
    move.b  song_title, $00FFD502
    move.b  load_ok, $00FFD503
    move.b  files_error, $00FFD504
    movem.l (sp)+, d0-d7/a0-a6
.tlbdone:
"""

LOAD_BAD_RLE = """    tst.b   $00FFD500
    bne.s   .tlrdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #$2A, song
    bsr     dir_save
    move.l  #DIR_BASE+4, d0
    bsr     sram_at
    move.b  #0, (a1)
    adda.l  d5, a1
    move.b  #1, (a1)
    move.b  #0, $A130F1
    move.b  #$77, song
    moveq   #0, d0
    bsr     dir_load
    move.b  song, $00FFD501
    move.b  load_ok, $00FFD502
    move.b  files_error, $00FFD503
    movem.l (sp)+, d0-d7/a0-a6
.tlrdone:
"""

CONT_BAD_RELOAD = """    tst.b   $00FFD500
    bne     .tcbrdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #$2A, song
    bsr     dir_save
    move.l  #DIR_BASE+14, d0
    bsr     sram_at
    eori.b  #1, (a1)                       ; make target slot 0 fail its checksum
    move.b  #0, $A130F1
    move.b  #1, proj_mode
    move.b  #0, ch_state+c_track
    move.b  #0, ch_state+c_instr
    move.b  #0, ch_state+c_chain
    move.b  #15, ch_state+c_row
    move.b  #1, ch_state+c_type
    move.l  #phrases, ch_state+c_phrase
    move.b  #6, instrum+i_algo
    move.b  #$30, phrases
    move.b  #0, phrases+1
    move.w  #1, cont_mask
    bsr     cont_snapshot_all
    move.b  #$31, phrases
    move.b  #31, phrases+1
    move.b  #4, instrum+(30*INSTR_SIZE)+i_algo
    bsr     cont_plant_all                 ; active bridge borrows target slot 30
    moveq   #0, d0
    bsr     cont_do_load                   ; validation must fail before a new snapshot is taken
    move.b  ch_state+c_chain, $00FFD100
    move.b  carry_slot, $00FFD101
    move.b  cont_active, $00FFD102
    move.b  ch_state+c_instr, $00FFD103
    move.b  instrum+(30*INSTR_SIZE)+i_algo, $00FFD104
    move.b  carry_instr+i_algo, $00FFD105
    move.b  carry_buf+1, $00FFD106
    move.b  load_ok, $00FFD107
    move.b  files_error, $00FFD108
    movem.l (sp)+, d0-d7/a0-a6
.tcbrdone:
"""

SAVE_FREEZE = """    tst.b   $00FFD500
    bne.s   .tsfdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #1, save_busy
    move.b  #$55, patch_done
    bsr     engine_tick
    move.b  patch_done, $00FFD501
    clr.b   save_busy
    movem.l (sp)+, d0-d7/a0-a6
.tsfdone:
"""

CURSOR_BLOCK = """    tst.b   $00FFD500
    bne     .tcbdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #0, song
    move.b  #1, song+NCH
    move.b  #2, song+(2*NCH)
    move.b  #$FF, song+(3*NCH)
    move.b  #0, chains
    move.b  #0, chains+1
    move.b  #1, play_from
    move.b  #0, play_mode
    move.b  #0, proj_mode
    bsr     engine_play_reset
    move.b  ch_state+c_songpos, $00FFD501
    move.b  ch_state+c_chain, $00FFD502
    lea     ch_state, a6
    move.b  #2, c_songpos(a6)
    bsr     advance_song
    move.b  c_songpos(a6), $00FFD503
    move.b  c_chain(a6), $00FFD504
    movem.l (sp)+, d0-d7/a0-a6
.tcbdone:
"""

START_FROM_SONG_CURSOR = """    tst.b   $00FFD500
    bne     .tscsdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #SCR_SONG, cur_screen
    move.b  #4, song_page
    move.b  #6, cur_row
    move.b  #0, proj_mode
    move.b  #7, song+(70*NCH)
    move.b  #0, chains+(7*CHAIN_SIZE)
    clr.b   playing
    bsr     start_button
    move.b  play_from, $00FFD501
    move.b  ch_state+c_songpos, $00FFD502
    move.b  ch_state+c_chain, $00FFD503
    move.b  playing, $00FFD504
    bsr     start_button
    move.b  playing, $00FFD505
    move.b  #$AA, play_from
    move.b  #3, opt_sync
    bsr     start_button
    move.b  play_from, $00FFD506
    move.b  sync_wait, $00FFD507
    move.b  ch_state+c_songpos, $00FFD508
    bsr     start_button
    move.b  #$AA, play_from
    bsr     play_context
    move.b  play_from, $00FFD509
    move.b  sync_wait, $00FFD50A
    move.b  ch_state+c_songpos, $00FFD50B
    bsr     play_context
    move.b  #0, opt_sync
    move.b  #SCR_PHRASE, cur_screen
    move.b  #$AA, play_from
    bsr     start_button
    move.b  play_from, $00FFD50C
    movem.l (sp)+, d0-d7/a0-a6
.tscsdone:
"""

PHRASE_ITERATION = """    tst.b   $00FFD500
    bne     .tipdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #0, play_mode
    move.b  #0, song
    move.b  #$FF, song+NCH
    move.b  #0, chains
    move.b  #0, chains+1
    move.b  #$FF, chains+2
    move.b  #48, phrases
    move.b  #0, phrases+1
    move.b  #9, phrases+2
    move.b  #$AA, phrases+3
    move.b  #0, instrum+i_type
    move.b  #0, instrum+i_tsp
    move.b  #$FF, instrum+i_tbl
    clr.b   phrase_plays
    lea     ch_state, a6
    move.b  #0, c_chain(a6)
    move.b  #$FF, c_cstep(a6)
    move.b  #15, c_row(a6)
    move.b  #0, c_track(a6)
    move.b  #0, c_songpos(a6)
    move.b  #0, c_transp(a6)
    move.b  #1, c_type(a6)
    move.l  #phrases, c_phrase(a6)

    move.b  #40, c_note(a6)
    bsr     advance_ch
    move.b  phrase_plays, $00FFD501
    move.b  c_note(a6), $00FFD502
    move.b  #15, c_row(a6)
    move.b  #40, c_note(a6)
    bsr     advance_ch
    move.b  phrase_plays, $00FFD503
    move.b  c_note(a6), $00FFD504
    move.b  #15, c_row(a6)
    move.b  #40, c_note(a6)
    bsr     advance_ch
    move.b  phrase_plays, $00FFD505
    move.b  c_note(a6), $00FFD506
    move.b  #15, c_row(a6)
    move.b  #40, c_note(a6)
    bsr     advance_ch
    move.b  phrase_plays, $00FFD507
    move.b  c_note(a6), $00FFD508

    clr.b   phrase_plays+1
    move.b  #$FF, phrases+PHRASE_SIZE
    move.l  #phrases+PHRASE_SIZE, c_phrase(a6)
    move.b  #CONT_BRIDGE, c_chain(a6)
    move.b  #15, c_row(a6)
    bsr     advance_ch
    move.b  phrase_plays+1, $00FFD509
    movem.l (sp)+, d0-d7/a0-a6
.tipdone:
"""

DEEP_CLONE_ALIASES = """    tst.b   $00FFD500
    bne     .tdcdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #0, chains
    move.b  #0, chains+1
    move.b  #1, chains+2
    move.b  #$0C, chains+3
    move.b  #0, chains+4
    move.b  #$F4, chains+5
    move.b  #0, chains+6
    move.b  #7, chains+7
    move.b  #40, phrases
    move.b  #41, phrases+PHRASE_SIZE
    moveq   #0, d3
    bsr     chain_unique_phrase_count
    move.b  d1, $00FFD501
    moveq   #0, d3
    moveq   #2, d0
    lea     chains, a0
    moveq   #CHAIN_SIZE, d1
    bsr     clone_rec
    bsr     deep_chain_phrases
    lea     chains+(2*CHAIN_SIZE), a0
    move.b  (a0), $00FFD502
    move.b  2(a0), $00FFD503
    move.b  4(a0), $00FFD504
    move.b  6(a0), $00FFD505
    move.b  1(a0), $00FFD506
    move.b  3(a0), $00FFD507
    move.b  5(a0), $00FFD508
    move.b  7(a0), $00FFD509
    move.b  phrases+(2*PHRASE_SIZE), $00FFD50A
    move.b  phrases+(3*PHRASE_SIZE), $00FFD50B
    move.b  #99, phrases+(2*PHRASE_SIZE)
    move.b  phrases, $00FFD50C
    movem.l (sp)+, d0-d7/a0-a6
.tdcdone:
"""

PASTE_AND_MINT = """    tst.b   $00FFD500
    bne     .tpmdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #SCR_PHRASE, cur_screen
    clr.b   cur_phrase
    clr.b   cur_row
    clr.b   cur_col
    move.b  #SCR_PHRASE, clip_screen
    clr.b   clip_col0
    move.b  #1, clip_rows
    move.b  #1, clip_cols
    move.b  #37, clip_buf
    clr.l   ctap_addr
    move.w  #10, g_ticks
    bsr     c_tap_complete
    addq.w  #1, g_ticks
    bsr     c_tap_complete
    move.b  phrases, $00FFD501
    move.b  #SCR_SONG, cur_screen
    move.b  #SCR_SONG, clip_screen
    move.b  #99, clip_buf
    clr.b   cur_row
    clr.b   cur_col
    move.b  #5, song
    move.b  #0, chains+(5*CHAIN_SIZE)
    clr.l   btap_addr
    move.w  #20, g_ticks
    bsr     do_insert
    addq.w  #1, g_ticks
    bsr     do_insert
    move.b  song, $00FFD502
    move.b  chains+(6*CHAIN_SIZE), $00FFD503
    clr.l   ctap_addr
    clr.b   ctap_active
    moveq   #$40, d3
    moveq   #$40, d4
    moveq   #0, d6
    bsr     c_tap_track
    moveq   #$60, d3
    moveq   #$20, d4
    moveq   #0, d6
    bsr     c_tap_track
    moveq   #0, d3
    moveq   #0, d4
    moveq   #$60, d6
    bsr     c_tap_track
    tst.l   ctap_addr
    sne     $00FFD504
    movem.l (sp)+, d0-d7/a0-a6
.tpmdone:
"""

SONG_PAGE_ADDRESSING = """    tst.b   $00FFD500
    bne     .tspdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #SCR_SONG, cur_screen
    move.b  #1, song_page
    move.b  #10, cur_row
    clr.b   cur_col
    move.b  #$11, song+(10*NCH)
    clr.b   song+(26*NCH)
    moveq   #8, d2
    bsr     edit_value
    move.b  song+(10*NCH), $00FFD501
    move.b  song+(26*NCH), $00FFD502
    move.b  #3, song_page
    move.b  #15, cur_row
    move.b  #9, cur_col
    move.b  #$06, song+(15*NCH)+9
    move.b  #$05, song+(63*NCH)+9
    bsr     do_cut
    move.b  song+(15*NCH)+9, $00FFD503
    move.b  song+(63*NCH)+9, $00FFD504
    move.b  #4, song_page
    move.b  #6, cur_row
    move.b  #2, cur_col
    move.b  #5, song+(70*NCH)+2
    move.b  #6, song+(70*NCH)+3
    move.b  #0, chains+(5*CHAIN_SIZE)
    move.b  #1, chains+(6*CHAIN_SIZE)
    bsr     drill_down
    move.b  cur_songrow, $00FFD505
    move.b  cur_chain, $00FFD506
    move.b  #3, cur_chan
    bsr     load_chan
    move.b  cur_chain, $00FFD507
    move.b  #SCR_SONG, cur_screen
    move.b  #SCR_SONG, clip_screen
    move.b  #14, song_page
    move.b  #14, cur_row
    clr.b   cur_col
    clr.b   clip_col0
    move.b  #3, clip_rows
    move.b  #1, clip_cols
    move.b  #$A1, clip_buf
    move.b  #$A2, clip_buf+1
    move.b  #$A3, clip_buf+2
    move.b  #$5A, phrases
    bsr     block_paste
    move.b  song+(238*NCH), $00FFD508
    move.b  song+(239*NCH), $00FFD509
    move.b  phrases, $00FFD50A
    move.b  #SCR_PHRASE, cur_screen
    move.b  #SCR_PHRASE, clip_screen
    clr.b   cur_phrase
    move.b  #15, cur_row
    clr.b   cur_col
    clr.b   clip_col0
    move.b  #2, clip_rows
    move.b  #1, clip_cols
    move.b  #$B1, clip_buf
    move.b  #$B2, clip_buf+1
    move.b  #$5B, phrases+PHRASE_SIZE
    bsr     block_paste
    move.b  phrases+(15*4), $00FFD50B
    move.b  phrases+PHRASE_SIZE, $00FFD50C
    move.b  #SCR_SONG, cur_screen
    move.b  #2, song_page
    clr.b   cur_row
    clr.b   cur_col
    move.b  #1, sel_active
    moveq   #1, d2
    bsr     move_cursor
    move.b  song_page, $00FFD50D
    move.b  cur_row, $00FFD50E
    move.b  #15, cur_row
    moveq   #2, d2
    bsr     move_cursor
    move.b  song_page, $00FFD50F
    move.b  cur_row, $00FFD510
    clr.b   sel_active
    movem.l (sp)+, d0-d7/a0-a6
.tspdone:
"""

SONG_STRUCTURAL_EDIT = """    tst.b   $00FFD500
    bne     .tssedone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    lea     song, a0
    move.w  #(NSONGROWS*NCH)-1, d0
.tsseclear1:
    move.b  #$FF, (a0)+
    dbra    d0, .tsseclear1

    ; Single-track close-gap uses the absolute SONG page and preserves the clipboard.
    move.b  #$22, song+(34*NCH)+2
    move.b  #$33, song+(35*NCH)+2
    move.b  #$7A, clip_buf
    move.b  #2, song_page
    move.b  #1, cur_row
    move.b  #2, cur_col
    clr.b   sel_active
    bsr     song_gap_close
    move.b  song+(33*NCH)+2, $00FFD501
    move.b  song+(34*NCH)+2, $00FFD502
    move.b  song+(35*NCH)+2, $00FFD503
    move.b  clip_buf, $00FFD504

    ; A two-row/two-track selection shifts only those tracks and exits selection.
    lea     song, a0
    move.w  #(NSONGROWS*NCH)-1, d0
.tsseclear2:
    move.b  #$FF, (a0)+
    dbra    d0, .tsseclear2
    move.b  #$41, song+(68*NCH)+1
    move.b  #$42, song+(68*NCH)+2
    move.b  #$51, song+(69*NCH)+1
    move.b  #$52, song+(69*NCH)+2
    move.b  #$6A, song+(68*NCH)+0
    move.b  #4, song_page
    move.b  #3, cur_row
    move.b  #2, cur_col
    move.b  #2, sel_row0
    move.b  #1, sel_col0
    move.b  #1, sel_active
    bsr     song_gap_close
    move.b  song+(66*NCH)+1, $00FFD505
    move.b  song+(66*NCH)+2, $00FFD506
    move.b  song+(67*NCH)+1, $00FFD507
    move.b  song+(67*NCH)+2, $00FFD508
    move.b  song+(68*NCH)+0, $00FFD509
    move.b  sel_active, $00FFD50A

    ; Insert a two-row SONG clipboard, shifting its fixed source column downward.
    lea     song, a0
    move.w  #(NSONGROWS*NCH)-1, d0
.tsseclear3:
    move.b  #$FF, (a0)+
    dbra    d0, .tsseclear3
    move.b  #$66, song+(70*NCH)+2
    move.b  #$61, song+(70*NCH)+3
    move.b  #$62, song+(71*NCH)+3
    move.b  #$63, song+(72*NCH)+3
    move.b  #SCR_SONG, clip_screen
    move.b  #1, clip_col0                  ; source column differs: structural insert follows cursor
    move.b  #2, clip_rows
    move.b  #1, clip_cols
    move.b  #$A1, clip_buf
    move.b  #$A2, clip_buf+1
    move.b  #4, song_page
    move.b  #6, cur_row
    move.b  #3, cur_col
    clr.b   sel_active
    bsr     song_clip_insert
    move.b  song+(70*NCH)+3, $00FFD50B
    move.b  song+(71*NCH)+3, $00FFD50C
    move.b  song+(72*NCH)+3, $00FFD50D
    move.b  song+(73*NCH)+3, $00FFD50E
    move.b  song+(74*NCH)+3, $00FFD50F
    move.b  song+(70*NCH)+2, $00FFD510

    ; A populated tail refuses insertion transactionally.
    move.b  #$EE, song+(239*NCH)+3
    move.b  #1, clip_rows
    move.b  #$B1, clip_buf
    bsr     song_clip_insert
    move.b  song_edit_msg, $00FFD511
    move.b  song+(70*NCH)+3, $00FFD512
    move.b  song+(239*NCH)+3, $00FFD513

    ; Closing a populated cell refuses it, and a non-SONG clipboard is rejected.
    bsr     song_gap_close
    move.b  song_edit_msg, $00FFD514
    move.b  song+(70*NCH)+3, $00FFD515
    move.b  #SCR_PHRASE, clip_screen
    bsr     song_clip_insert
    move.b  song_edit_msg, $00FFD516

    ; Warning expiry clears both the message and its rendered-state dirty flag.
    move.b  #1, song_edit_ctr
    clr.b   vdirty
    bsr     song_edit_status_tick
    move.b  song_edit_msg, $00FFD517
    move.b  vdirty, $00FFD518

    ; Full-width row shifts exercise the zero-stride fast path in both directions.
    lea     song, a0
    move.w  #(NSONGROWS*NCH)-1, d0
.tsseclear4:
    move.b  #$FF, (a0)+
    dbra    d0, .tsseclear4
    move.b  #$10, song+(1*NCH)+0
    move.b  #$19, song+(1*NCH)+9
    clr.b   song_page
    clr.b   cur_row
    move.b  #9, cur_col
    clr.b   sel_row0
    clr.b   sel_col0
    move.b  #1, sel_active
    bsr     song_gap_close
    move.b  song+(0*NCH)+0, $00FFD519
    move.b  song+(0*NCH)+9, $00FFD51A

    lea     song, a0
    move.w  #(NSONGROWS*NCH)-1, d0
.tsseclear5:
    move.b  #$FF, (a0)+
    dbra    d0, .tsseclear5
    move.b  #$01, song+(10*NCH)+0
    move.b  #$09, song+(10*NCH)+9
    lea     clip_buf, a0
    moveq   #0, d0
.tsseclip10:
    move.b  d0, d1
    addi.b  #$C0, d1
    move.b  d1, (a0)+
    addq.b  #1, d0
    cmpi.b  #10, d0
    blo.s   .tsseclip10
    move.b  #SCR_SONG, clip_screen
    clr.b   clip_col0
    move.b  #1, clip_rows
    move.b  #10, clip_cols
    move.b  #10, cur_row
    clr.b   cur_col
    clr.b   sel_active
    bsr     song_clip_insert
    move.b  song+(10*NCH)+0, $00FFD51B
    move.b  song+(10*NCH)+9, $00FFD51C
    move.b  song+(11*NCH)+0, $00FFD51D
    move.b  song+(11*NCH)+9, $00FFD51E
    movem.l (sp)+, d0-d7/a0-a6
.tssedone:
"""

REFERENCE_EDIT = """    tst.b   $00FFD500
    bne     .tredone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #SCR_CHAIN, cur_screen
    clr.b   cur_chain
    clr.b   cur_row
    clr.b   cur_col
    move.b  #$80, chains
    moveq   #8, d2
    bsr     edit_value
    move.b  chains, $00FFD501
    move.b  #$BF, chains
    bsr     edit_value
    move.b  chains, $00FFD502
    moveq   #4, d2
    bsr     edit_value
    move.b  chains, $00FFD503
    move.b  #$FF, chains
    moveq   #8, d2
    bsr     edit_value
    move.b  chains, $00FFD504
    move.b  #SCR_SONG, cur_screen
    move.b  #$7F, song
    moveq   #8, d2
    bsr     edit_value
    move.b  song, $00FFD505
    move.b  #SCR_CHAIN, cur_screen
    move.b  #1, cur_col
    move.b  #$FF, chains+1
    bsr     edit_value
    move.b  chains+1, $00FFD506
    movem.l (sp)+, d0-d7/a0-a6
.tredone:
"""

CYCLIC_ALLOC = """    tst.b   $00FFD500
    bne     .tcadone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    lea     chains, a0
    move.w  #(NCHAINS*CHAIN_SIZE)-1, d0
.tca_ch:
    move.b  #$FF, (a0)+
    dbra    d0, .tca_ch
    lea     song, a0
    move.w  #(NSONGROWS*NCH)-1, d0
.tca_sg:
    move.b  #$FF, (a0)+
    dbra    d0, .tca_sg
    move.b  #31, song
    moveq   #30, d3
    bsr     find_free_chain
    move.b  d0, $00FFD501
    moveq   #127, d3
    bsr     find_free_chain
    move.b  d0, $00FFD502
    move.b  #31, chains
    moveq   #30, d3
    bsr     find_free_phrase
    move.b  d0, $00FFD503
    moveq   #191, d3
    bsr     find_free_phrase
    move.b  d0, $00FFD504
    movem.l (sp)+, d0-d7/a0-a6
.tcadone:
"""

FILES_CONFIRM = """    tst.b   $00FFD500
    bne     .tfcdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #1, files_menu
    move.b  #1, menu_row
    clr.b   opt_song
    move.b  #$55, song
    bsr     files_action
    move.b  proj_armed, d7
    move.b  song, d6
    addq.w  #1, g_ticks
    bsr     files_action
    move.b  d7, $00FFD800
    move.b  d6, $00FFD801
    move.b  song, $00FFD802
    move.b  #1, files_menu
    clr.b   menu_row
    clr.b   opt_song
    move.b  #$2A, song
    bsr     files_action
    move.b  proj_armed, $00FFD803
    bsr     dir_count
    move.b  d0, $00FFD804
    addq.w  #1, g_ticks
    bsr     files_action
    bsr     dir_count
    move.b  d0, $00FFD805
    move.b  #1, files_menu
    move.b  #2, menu_row
    clr.b   opt_song
    bsr     files_action
    bsr     dir_count
    move.b  d0, $00FFD806
    addq.w  #1, g_ticks
    bsr     files_action
    bsr     dir_count
    move.b  d0, $00FFD807
    move.b  #1, files_menu
    move.b  #3, menu_row
    move.b  #60, phrases+(10*PHRASE_SIZE)
    bsr     files_action
    move.b  phrases+(10*PHRASE_SIZE), $00FFD808
    addq.w  #1, g_ticks
    bsr     files_action
    move.b  phrases+(10*PHRASE_SIZE), $00FFD809
    move.b  #4, menu_row
    move.b  #0, chains+(10*CHAIN_SIZE)
    bsr     files_action
    move.b  chains+(10*CHAIN_SIZE), $00FFD80A
    addq.w  #1, g_ticks
    bsr     files_action
    move.b  chains+(10*CHAIN_SIZE), $00FFD80B
    movem.l (sp)+, d0-d7/a0-a6
.tfcdone:
"""

FILES_CONFIRM_CANCEL = """    tst.b   $00FFD500
    bne     .tfccdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  menu_row, $00FFD804
    move.b  #SCR_FILES, cur_screen
    move.b  #1, files_menu
    move.b  #CONF_SAVE, proj_armed
    move.w  #10, proj_arm_frame
    move.w  #10+CONFIRM_FRAMES+1, g_ticks
    clr.b   vdirty
    bsr     files_confirm_tick
    move.b  proj_armed, $00FFD800
    move.b  vdirty, $00FFD801
    move.b  #CONF_LOAD, proj_armed
    move.b  #1, menu_row
    moveq   #1, d2
    bsr     move_cursor
    move.b  proj_armed, $00FFD802
    move.b  menu_row, $00FFD803
    move.b  #2, sram_layout
    move.b  #CONF_LOAD, proj_armed
    bsr     files_menu_toggle
    move.b  proj_armed, $00FFD805
    move.b  #2, menu_row
    bsr     files_menu_toggle
    move.b  menu_row, $00FFD806
    move.b  files_menu, $00FFD807
    movem.l (sp)+, d0-d7/a0-a6
.tfccdone:
"""

FILES_TITLE = """    move.b  #SCR_FILES, cur_screen
    move.l  #$54455354, song_title          ; TEST
    move.l  #$534F4E47, song_title+4        ; SONG
"""

FM_SIMULTANEOUS = """    tst.b   $00FFD500
    bne     .tfsdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #3, pshadow
    move.b  #4, pshadow+1
    bsr     engine_play_reset
    move.b  pshadow, $00FFD800
    move.b  pshadow+1, $00FFD801
    clr.b   repatch
    move.b  #$FF, live_algo
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    bsr     clear_live_patch
    move.b  repatch, $00FFD802

    lea     ch_state, a6
    move.b  #0, c_instr(a6)
    move.b  #48, c_note(a6)
    move.b  #1, c_trig(a6)
    move.b  #1, c_keyon(a6)
    move.b  #$FF, c_tvol(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #$FF, pshadow
    lea     CHSIZE(a6), a6
    move.b  #0, c_instr(a6)
    move.b  #48, c_note(a6)
    move.b  #1, c_trig(a6)
    move.b  #1, c_keyon(a6)
    move.b  #$FF, c_tvol(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #$FF, pshadow+1
    move.b  #1, lq_dirty
    move.b  #1, lq_dirty+1
    move.b  #1, lx_dirty
    move.b  #1, lx_dirty+1
    move.b  #15, lx_vol
    move.b  #15, lx_vol+1
    move.b  #1, lo_dirty
    move.b  #1, lo_dirty+1
    move.b  #1, lu_dirty
    move.b  #1, lu_dirty+1
    clr.b   patch_done
    clr.b   fm_keypend
    lea     ym_data, a5
    moveq   #0, d5
    lea     ch_state, a6
    bsr     compose_fm
    lea     CHSIZE(a6), a6
    bsr     compose_fm
    bsr     flush_fm_keyons
    move.b  d5, $00FFD803
    move.b  ch_state+c_trig, $00FFD804
    move.b  ch_state+CHSIZE+c_trig, $00FFD805
    move.b  patch_done, $00FFD806
    move.b  -6(a5), $00FFD807
    move.b  -5(a5), $00FFD808
    move.b  -4(a5), $00FFD809
    move.b  -3(a5), $00FFD80A
    move.b  -2(a5), $00FFD80B
    move.b  -1(a5), $00FFD80C

    lea     ch_state, a6
    move.b  #49, c_note(a6)
    move.b  #1, c_trig(a6)
    move.w  #$FFFF, c_shadowp(a6)
    lea     CHSIZE(a6), a6
    move.b  #49, c_note(a6)
    move.b  #1, c_trig(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #1, lq_dirty
    move.b  #1, lq_dirty+1
    move.b  #1, lx_dirty
    move.b  #1, lx_dirty+1
    move.b  #1, lo_dirty
    move.b  #1, lo_dirty+1
    move.b  #1, lu_dirty
    move.b  #1, lu_dirty+1
    clr.b   patch_done
    clr.b   fm_keypend
    lea     ym_data, a5
    moveq   #0, d5
    lea     ch_state, a6
    bsr     compose_fm
    lea     CHSIZE(a6), a6
    bsr     compose_fm
    bsr     flush_fm_keyons
    move.b  d5, $00FFD80D
    move.b  patch_done, $00FFD80E
    move.b  -6(a5), $00FFD80F
    move.b  -5(a5), $00FFD810
    move.b  -4(a5), $00FFD811
    move.b  -3(a5), $00FFD812
    move.b  -2(a5), $00FFD813
    move.b  -1(a5), $00FFD814
    movem.l (sp)+, d0-d7/a0-a6
.tfsdone:
"""

FM_SSG_EG = """    tst.b   $00FFD820
    bne     .tssgdone
    move.b  #1, $00FFD820
    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    lea     instrum, a0
    move.b  #$81, (i_op+5,a0)                    ; SSG 8 + AM on
    move.b  #$A0, (i_op+FM_NPARM+5,a0)           ; SSG A + AM off
    move.b  #$F1, (i_op+(2*FM_NPARM)+5,a0)       ; SSG F + AM on
    move.b  #$70, (i_op+(3*FM_NPARM)+5,a0)       ; invalid old nibble -> OFF
    bsr     sanitize_fm_ssg_record
    move.b  (i_op+5,a0), $00FFD821
    move.b  (i_op+FM_NPARM+5,a0), $00FFD822
    move.b  (i_op+(2*FM_NPARM)+5,a0), $00FFD823
    move.b  (i_op+(3*FM_NPARM)+5,a0), $00FFD824

    move.b  #SCR_INSTR, cur_screen
    clr.b   cur_instr
    move.b  #NVOICE+2, cur_row
    move.b  #FM_NPARM, cur_col
    move.b  #1, (i_op+5,a0)                    ; OFF + AM on
    moveq   #8, d2                             ; Right: OFF -> 8
    bsr     edit_fm
    move.b  instrum+i_op+5, $00FFD825
    moveq   #4, d2                             ; Left: 8 -> OFF
    bsr     edit_fm
    move.b  instrum+i_op+5, $00FFD826
    move.b  #9, cur_col                        ; AM edit preserves SSG A
    move.b  #$A0, instrum+i_op+5
    moveq   #8, d2
    bsr     edit_fm
    move.b  instrum+i_op+5, $00FFD827
    move.b  #FM_NPARM, cur_col
    bsr     col_max
    move.b  d1, $00FFD828

    move.b  #$81, instrum+i_op+5
    move.b  #5, instrum+i_op+6
    move.b  #$A0, instrum+i_op+FM_NPARM+5
    move.b  #6, instrum+i_op+FM_NPARM+6
    move.b  #$F1, instrum+i_op+(2*FM_NPARM)+5
    move.b  #7, instrum+i_op+(2*FM_NPARM)+6
    clr.b   instrum+i_op+(3*FM_NPARM)+5
    move.b  #8, instrum+i_op+(3*FM_NPARM)+6
    move.b  #$FF, c_eatk
    move.b  #$FF, c_edcy
    lea     ch_state, a6
    clr.b   c_ympart(a6)
    clr.b   c_ymchreg(a6)
    clr.b   c_track(a6)
    lea     ym_data, a5
    moveq   #0, d5
    moveq   #0, d1
    bsr     emit_ch_patch
    move.b  d5, $00FFD829
    move.b  ym_data+10, $00FFD82A             ; op1 $60 register/value
    move.b  ym_data+11, $00FFD82B
    move.b  ym_data+19, $00FFD82C             ; op1 $90 register/value
    move.b  ym_data+20, $00FFD82D
    move.b  ym_data+40, $00FFD82E             ; op3 $90 register/value
    move.b  ym_data+41, $00FFD82F
    move.b  ym_data+61, $00FFD830             ; op2 $90 register/value
    move.b  ym_data+62, $00FFD831
    move.b  ym_data+82, $00FFD832             ; op4 $90 register/value
    move.b  ym_data+83, $00FFD833

    clr.b   playing
    clr.b   cur_instr
    move.b  #$FF, live_algo
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    lea     ym_data, a2
    moveq   #0, d7
    bsr     ym_build_patch
    move.b  d7, $00FFD834
    move.b  ym_data+19, $00FFD835
    move.b  ym_data+20, $00FFD836
    move.b  ym_data+40, $00FFD837
    move.b  ym_data+41, $00FFD838
    move.b  ym_data+61, $00FFD839
    move.b  ym_data+62, $00FFD83A
    move.b  ym_data+82, $00FFD83B
    move.b  ym_data+83, $00FFD83C

    ; FM S58: logical OP1+OP3 mask -> physical $90/$94 writes, shape 8
    lea     ch_state, a6
    move.b  #1, c_type(a6)
    clr.b   c_track(a6)
    clr.b   c_instr(a6)
    clr.b   c_ssgmask
    clr.b   c_ssgmode
    clr.b   c_ssgdirty
    clr.b   s_set
    move.b  #48, phrases
    clr.b   phrases+1
    move.b  #19, phrases+2
    move.b  #$58, phrases+3
    lea     phrases, a1
    moveq   #0, d1
    bsr     exec_cmd
    move.b  c_ssgmask, $00FFD83D
    move.b  c_ssgmode, $00FFD83E
    move.b  c_ssgdirty, $00FFD83F
    move.b  s_set, $00FFD840
    lea     ym_data, a5
    moveq   #0, d5
    bsr     emit_s_ssg
    move.b  d5, $00FFD841
    move.b  ym_data, $00FFD842
    move.b  ym_data+1, $00FFD843
    move.b  ym_data+2, $00FFD844
    move.b  ym_data+3, $00FFD845
    move.b  ym_data+4, $00FFD846
    move.b  ym_data+5, $00FFD847
    move.b  c_ssgdirty, $00FFD848

    ; reserved FM shape 1 is rejected without changing/rearming the live state
    clr.b   s_set
    move.b  #$51, phrases+3
    lea     phrases, a1
    moveq   #0, d1
    bsr     exec_cmd
    move.b  c_ssgmask, $00FFD849
    move.b  c_ssgmode, $00FFD84A
    move.b  c_ssgdirty, $00FFD84B
    move.b  s_set, $00FFD84C

    ; the same S command on a genuine KIT keeps the old low-two-bit rate behavior
    move.b  #1, instrum+INSTR_SIZE+i_type
    move.b  #1, phrases+1
    move.b  #$03, phrases+3
    move.b  #5, c_track(a6)
    move.b  #$FF, c_srate+5
    lea     phrases, a1
    moveq   #0, d1
    bsr     exec_cmd
    move.b  c_srate+5, $00FFD84D
    move.b  c_ssgmask, $00FFD84E
    move.b  c_ssgdirty, $00FFD84F

    ; even a genuine FM instrument cannot use SSG-EG from a PSG hardware track
    clr.b   c_track(a6)
    clr.b   c_type(a6)
    clr.b   phrases+1
    move.b  #$F8, phrases+3
    clr.b   s_set
    lea     phrases, a1
    moveq   #0, d1
    bsr     exec_cmd
    move.b  c_ssgmask, $00FFD850
    move.b  s_set, $00FFD851

    ; removing the override restores all four stored shapes in logical/physical order
    move.b  #1, c_type(a6)
    clr.b   c_ssgmask
    move.b  #$0F, c_ssgdirty
    lea     ym_data, a5
    moveq   #0, d5
    bsr     emit_s_ssg
    move.b  d5, $00FFD852
    move.b  ym_data, $00FFD853
    move.b  ym_data+1, $00FFD854
    move.b  ym_data+2, $00FFD855
    move.b  ym_data+3, $00FFD856
    move.b  ym_data+4, $00FFD857
    move.b  ym_data+5, $00FFD858
    move.b  ym_data+6, $00FFD859
    move.b  ym_data+7, $00FFD85A
    move.b  ym_data+8, $00FFD85B
    move.b  ym_data+9, $00FFD85C
    move.b  ym_data+10, $00FFD85D
    move.b  ym_data+11, $00FFD85E
    movem.l (sp)+, d0-d7/a0-a6
.tssgdone:
"""

# FM/PERC SWEEP is a raw YM2612 F-number slide, not a semitone-table offset.
# A non-zero SWEEP ignores pitch class, targeting C in the note/operator's octave.
# $42 starts 16 internal units high (= 256 F-number steps) and decays by
# two units/frame (= 32 F-number steps). $30 verifies the zero-rate hold case.
FM_FNUM_SWEEP = """    tst.b   $00FFD860
    bne     .tfswdone
    move.b  #1, $00FFD860
    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    clr.b   scale_key
    clr.b   scale_type
    lea     instrum, a0
    clr.b   (i_type,a0)
    move.b  #$42, (i_psweep,a0)
    lea     ch_state, a6
    clr.b   c_instr(a6)
    clr.b   c_track(a6)
    move.b  #1, c_type(a6)
    clr.b   c_ympart(a6)
    clr.b   c_ymchreg(a6)
    move.b  #59, c_note(a6)                 ; B4: SWEEP must ignore pitch class and target C4 ($2284)
    clr.b   c_ttsp(a6)
    bsr     init_psweep                     ; $42 -> 16 units -> +256 F-number
    move.b  c_psweep(a6), $00FFD861
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD862             ; expected high $23
    move.b  ym_data+5, $00FFD863             ; expected low $84 ($284 + $100 = $384)
    bsr     decay_psweep                     ; rate 2 -> 14 units -> +224 F-number
    move.b  c_psweep(a6), $00FFD864
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD865             ; expected high $23
    move.b  ym_data+5, $00FFD866             ; expected low $64 ($284 + $0E0 = $364)

    move.b  #$30, (i_psweep,a0)              ; depth 3, rate 0: fixed +192 F-number
    bsr     init_psweep
    move.b  c_psweep(a6), $00FFD867
    bsr     decay_psweep
    move.b  c_psweep(a6), $00FFD868

    move.b  #$1F, (i_psweep,a0)              ; faster than depth: must still emit the exact target once
    bsr     init_psweep
    bsr     decay_psweep
    move.b  c_psweep(a6), $00FFD872           ; $80 = final target write pending
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD873             ; target C high $22
    move.b  ym_data+5, $00FFD874             ; target C low $84
    move.b  c_psweep(a6), $00FFD875           ; final write consumed -> inactive

    move.b  #5, (i_type,a0)                  ; PERC/F3: sweep every CH3 operator equally
    move.b  #1, (i_pbase,a0)
    clr.b   (i_pmode,a0)
    clr.b   instrum+INSTR_SIZE+i_type
    move.w  #$2298, instrum+i_op
    move.w  #$2298, instrum+i_op+FM_NPARM
    move.w  #$2298, instrum+i_op+(2*FM_NPARM)
    move.w  #$2298, instrum+i_op+(3*FM_NPARM)
    move.w  #$2298, perc_live               ; deliberately different F-numbers and octave blocks
    move.w  #$1ABC, perc_live+2
    move.w  #$32FF, perc_live+4
    move.w  #$0AB0, perc_live+6
    move.b  #2, c_track(a6)
    move.b  #16, c_psweep(a6)                ; each op -> its block's C F-number + $100
    lea     ym_data, a5
    moveq   #0, d5
    bsr     perc_freq_send
    move.b  ym_data+5, $00FFD869             ; first operator high $23
    move.b  ym_data+8, $00FFD86A             ; first operator low $98
    move.b  ym_data+14, $00FFD86B
    move.b  ym_data+17, $00FFD86C
    move.b  ym_data+23, $00FFD86D
    move.b  ym_data+26, $00FFD86E
    move.b  ym_data+32, $00FFD86F
    move.b  ym_data+35, $00FFD870
    move.b  d5, $00FFD871                    ; four MUL/frequency groups + B0/B4 = 14 triples

    clr.b   (i_type,a0)                      ; ordinary FM again
    clr.b   (i_psweep,a0)                    ; $00: normal B4 pitch must remain intact
    clr.b   c_track(a6)
    clr.b   c_psweep(a6)
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD876             ; B4 = $24BF
    move.b  ym_data+5, $00FFD877
    move.b  #$0F, (i_psweep,a0)              ; non-zero with zero depth: immediate octave-C target
    bsr     init_psweep
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD878             ; C4 = $2284
    move.b  ym_data+5, $00FFD879
    move.b  c_psweep(a6), $00FFD87A           ; no residual offset was armed
    movem.l (sp)+, d0-d7/a0-a6
.tfswdone:
"""

# B is deliberately overloaded by effective instrument type: FM/PERC use the packed XY
# as a per-note FSWP override, WAVE retains bank select, and incompatible placements ignore it.
FM_FSWP_COMMAND = """    tst.b   $00FFD87F
    bne     .tfbc_done
    move.b  #1, $00FFD87F
    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    lea     instrum, a0
    clr.b   (i_type,a0)                    ; instrument 0 = FM, stored FSWP $42
    move.b  #$42, (i_psweep,a0)
    move.b  #2, (INSTR_SIZE+i_type,a0)     ; instrument 1 = WAVE
    move.b  #5, (2*INSTR_SIZE+i_type,a0)   ; instrument 2 = PERC
    lea     ch_state, a6
    clr.b   c_track(a6)
    clr.b   c_instr(a6)
    move.b  #1, c_type(a6)
    move.b  #59, c_note(a6)                ; B4: active FSWP must target the octave's C
    clr.w   c_fswpovr
    clr.b   b_set
    move.b  #$FF, c_wbank+5
    lea     phrases, a1
    move.b  #59, (a1)
    clr.b   1(a1)                          ; row instrument 0 = FM
    move.b  #2, 2(a1)                      ; B command
    move.b  #$13, 3(a1)                    ; depth 1, rate 3
    moveq   #0, d1
    bsr     exec_cmd
    move.b  c_fswpcfg, $00FFD880
    move.b  c_fswpovr, $00FFD881
    move.b  c_fswpovr+1, $00FFD882
    move.b  b_set, $00FFD883
    move.b  c_psweep(a6), $00FFD884         ; depth 1 -> four internal units
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD885            ; C4 + 64 F-num = $22C4
    move.b  ym_data+5, $00FFD886
    bsr     decay_psweep
    move.b  c_psweep(a6), $00FFD887         ; 4 - rate 3 = one unit

    lea     phrases, a1
    moveq   #0, d1
    clr.b   3(a1)                          ; B00 disables FSWP for this note
    clr.b   b_set
    bsr     exec_cmd
    move.b  c_fswpcfg, $00FFD888
    move.b  c_fswpovr, $00FFD889
    move.b  c_fswpovr+1, $00FFD88A
    move.b  b_set, $00FFD88B
    move.b  c_psweep(a6), $00FFD88C         ; $80 requests one normal-pitch update
    lea     ym_data, a5
    moveq   #0, d5
    bsr     fm_freq_send
    move.b  ym_data+2, $00FFD88D            ; normal B4 = $24BF
    move.b  ym_data+5, $00FFD88E
    move.b  c_psweep(a6), $00FFD88F         ; marker consumed

    clr.b   b_set                           ; next ordinary note restores stored instrument FSWP
    bsr     fswp_note_reset
    bsr     get_fswp_cfg
    move.b  d0, $00FFD890                   ; stored $42 visible again
    move.b  c_fswpovr, $00FFD891
    move.b  c_fswpovr+1, $00FFD892

    move.b  #5, c_track(a6)                ; WAVE on F6: B still selects its bank
    move.b  #1, c_instr(a6)
    lea     phrases, a1
    moveq   #0, d1
    move.b  #1, 1(a1)
    move.b  #$0A, 3(a1)
    clr.b   b_set
    bsr     exec_cmd
    move.b  c_wbank+5, $00FFD893
    move.b  b_set, $00FFD894
    move.b  c_fswpovr+1, $00FFD895

    move.b  #2, c_track(a6)                ; PERC is valid only on F3
    move.b  #2, c_instr(a6)
    lea     phrases, a1
    moveq   #0, d1
    move.b  #2, 1(a1)
    move.b  #$24, 3(a1)
    clr.b   b_set
    bsr     exec_cmd
    move.b  c_fswpcfg+2, $00FFD896
    move.b  c_fswpovr+1, $00FFD897
    move.b  b_set, $00FFD898

    clr.w   c_fswpovr                      ; the same PERC instrument on F1 must be rejected
    clr.b   b_set
    clr.b   c_track(a6)
    lea     phrases, a1
    moveq   #0, d1
    move.b  #$35, 3(a1)
    bsr     exec_cmd
    move.b  c_fswpovr+1, $00FFD899
    move.b  b_set, $00FFD89A
    movem.l (sp)+, d0-d7/a0-a6
.tfbc_done:
"""

FM_PREWARM = """    tst.b   $00FFD500
    bne     .tfpdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    move.b  #1, instrum+(31*INSTR_SIZE)   ; first F1 note is KIT: skip it and predict the later FM note
    move.b  #0, song+(2*NCH)+0
    move.b  #1, song+1
    move.b  #2, song+2
    move.b  #3, song+3
    move.b  #4, song+4
    move.b  #5, song+5
    move.b  #0, chains+(0*CHAIN_SIZE)
    move.b  #1, chains+(1*CHAIN_SIZE)
    move.b  #2, chains+(2*CHAIN_SIZE)
    move.b  #3, chains+(3*CHAIN_SIZE)
    move.b  #4, chains+(4*CHAIN_SIZE)
    move.b  #5, chains+(5*CHAIN_SIZE)
    move.b  #48, phrases+(0*PHRASE_SIZE)
    move.b  #31, phrases+(0*PHRASE_SIZE)+1
    move.b  #49, phrases+(0*PHRASE_SIZE)+4
    move.b  #0, phrases+(0*PHRASE_SIZE)+5
    move.b  #49, phrases+(1*PHRASE_SIZE)
    move.b  #1, phrases+(1*PHRASE_SIZE)+1
    move.b  #50, phrases+(2*PHRASE_SIZE)
    move.b  #2, phrases+(2*PHRASE_SIZE)+1
    move.b  #51, phrases+(3*PHRASE_SIZE)
    move.b  #3, phrases+(3*PHRASE_SIZE)+1
    move.b  #52, phrases+(4*PHRASE_SIZE)
    move.b  #4, phrases+(4*PHRASE_SIZE)+1
    move.b  #53, phrases+(5*PHRASE_SIZE)
    move.b  #5, phrases+(5*PHRASE_SIZE)+1
    bsr     fm_prewarm_plan
    move.b  fm_pre_mask, $00FFD800
    lea     fm_pre_inst, a0
    lea     $00FFD801, a1
    moveq   #5, d0
.tfp_copy:
    move.b  (a0)+, (a1)+
    dbra    d0, .tfp_copy

    clr.b   patch_done
    lea     ym_data, a5
    moveq   #0, d5
    lea     ch_state, a6
    bsr     fm_prewarm_service
    move.b  fm_pre_mask, $00FFD807
    move.b  d5, $00FFD808
    move.b  pshadow, $00FFD809
    move.b  pshadow+1, $00FFD80A
    clr.b   patch_done
    lea     ym_data, a5
    moveq   #0, d5
    lea     ch_state, a6
    bsr     fm_prewarm_service
    move.b  fm_pre_mask, $00FFD80B
    move.b  d5, $00FFD80C
    clr.b   patch_done
    lea     ym_data, a5
    moveq   #0, d5
    lea     ch_state, a6
    bsr     fm_prewarm_service
    move.b  fm_pre_mask, $00FFD80D
    move.b  d5, $00FFD80E
    move.b  pshadow+4, $00FFD80F
    move.b  pshadow+5, $00FFD810
    bsr     fm_prewarm_plan
    move.b  #2, cur_chan
    moveq   #54, d1
    moveq   #6, d2
    bsr     audit_voice
    move.b  fm_pre_mask, $00FFD811
    bsr     engine_play_reset
    move.b  fm_pre_mask, $00FFD812
    movem.l (sp)+, d0-d7/a0-a6
.tfpdone:
"""

CUT_PRIMES_INSERT = """    tst.b   $00FFD500
    bne     .tcpdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #SCR_SONG, cur_screen
    clr.b   cur_row
    clr.b   cur_col
    move.b  #12, song
    bsr     do_cut
    move.b  song, $00FFD800
    move.b  last_chain, $00FFD801
    move.b  #1, cur_row
    bsr     do_insert
    move.b  song+NCH, $00FFD802
    move.b  #SCR_CHAIN, cur_screen
    clr.b   cur_chain
    clr.b   cur_row
    clr.b   cur_col
    move.b  #$82, chains
    bsr     do_cut
    move.b  chains, $00FFD803
    move.b  last_phrase, $00FFD804
    move.b  #1, cur_row
    bsr     do_insert
    move.b  chains+2, $00FFD805
    move.b  #SCR_PHRASE, cur_screen
    clr.b   cur_phrase
    clr.b   cur_row
    clr.b   cur_col
    move.b  #55, phrases
    bsr     do_cut
    move.b  last_note, $00FFD806
    move.b  #1, cur_row
    bsr     do_insert
    move.b  phrases+4, $00FFD807
    clr.b   cur_row
    move.b  #1, cur_col
    move.b  #7, phrases+1
    bsr     do_cut
    move.b  last_instr, $00FFD808
    move.b  #2, cur_col
    move.b  #4, phrases+2
    move.b  #$AB, phrases+3
    bsr     do_cut
    move.b  last_cmd, $00FFD809
    move.b  last_cprm, $00FFD80A
    move.b  #2, cur_row
    bsr     do_insert
    move.b  phrases+10, $00FFD80B
    move.b  phrases+11, $00FFD80C
    move.b  #3, cur_col
    move.b  #9, phrases+10
    move.b  #$3C, phrases+11
    bsr     do_cut
    move.b  last_cprm, $00FFD80D
    move.b  #66, last_note
    move.b  #$FF, phrases+12
    move.b  #3, cur_row
    clr.b   cur_col
    bsr     do_cut
    move.b  last_note, $00FFD80E
    movem.l (sp)+, d0-d7/a0-a6
.tcpdone:
"""

GROUP_OWNERSHIP = """    tst.b   $00FFD500
    bne     .tgodone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    move.b  #3, instrum+i_type
    clr.b   instrum+i_cluster
    move.b  #3, instrum+INSTR_SIZE+i_type
    move.b  #7, instrum+INSTR_SIZE+i_cluster
    clr.b   c_set
    clr.b   clu_claim
    lea     ch_state+(6*CHSIZE), a6
    move.b  #1, c_instr(a6)
    move.b  #48, c_note(a6)
    bsr     note_trigger
    move.b  clu_claim, $00FFD501
    lea     ch_state+(7*CHSIZE), a6
    move.b  #1, c_instr(a6)
    move.b  #52, c_note(a6)
    bsr     note_trigger
    move.b  clu_claim, $00FFD502
    move.b  #7, clu_mode
    move.w  #400, clu_period
    move.b  #15, clu_vol
    clr.b   clu_rd1
    clr.b   clu_rd2
    move.b  #$47, clu_chord
    moveq   #5, d1
    move.w  #333, d2
    bsr     cluster_hook
    move.w  d2, $00FFD506
    move.b  d1, $00FFD50A
    lea     ch_state+(8*CHSIZE), a6
    move.b  #1, c_instr(a6)
    move.b  #55, c_note(a6)
    moveq   #5, d1
    move.w  #333, d2
    bsr     cluster_hook
    move.w  d2, $00FFD508
    move.b  d1, $00FFD50B
    bsr     note_trigger
    move.b  clu_claim, $00FFD503
    lea     ch_state+(6*CHSIZE), a6
    move.b  #1, c_instr(a6)
    bsr     note_trigger
    move.b  clu_claim, $00FFD504
    move.b  #0, c_instr(a6)
    bsr     note_trigger
    move.b  clu_claim, $00FFD505
    move.b  #$FF, $00FFD514
    move.b  #1, $00FFD515
    move.b  #3, $00FFD516
    move.b  #$47, $00FFD517
    move.b  #1, c_instr(a6)
    lea     $00FFD514, a1
    moveq   #0, d1
    bsr     exec_cmd
    move.b  clu_claim, $00FFD50C
    move.b  #0, $00FFD517
    bsr     exec_cmd
    move.b  clu_claim, $00FFD50D
    bsr     note_trigger
    move.b  clu_claim, $00FFD50E
    bsr     note_trigger
    move.b  clu_claim, $00FFD50F
    lea     ch_state+(7*CHSIZE), a6
    bsr     note_trigger
    move.b  clu_claim, $00FFD510
    movem.l (sp)+, d0-d7/a0-a6
.tgodone:
"""

FM_GROUP_OWNERSHIP = """    tst.b   $00FFD500
    bne     .tfgdone
    move.b  #1, $00FFD500
    movem.l d0-d7/a0-a6, -(sp)
    bsr     clear_song
    lea     instrum, a0
    clr.b   (i_type,a0)                    ; instrument 0 = genuine FM, GROUP=CHORD
    move.b  #1, (i_fgroup,a0)
    move.b  #15, (i_hld,a0)
    move.b  #15, (i_vol,a0)
    move.b  #$FF, (i_tbl,a0)
    move.b  #$47, fmgrp_chord              ; root + major third + fifth
    lea     ch_state, a6                   ; F1 root
    clr.b   c_instr(a6)
    move.b  #48, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD8A0
    move.b  fmgrp_owner+2, $00FFD8A1
    move.b  ch_state+CHSIZE+c_note, $00FFD8A2
    move.b  ch_state+(2*CHSIZE)+c_note, $00FFD8A3
    move.b  ch_state+CHSIZE+c_instr, $00FFD8A4
    move.b  ch_state+(2*CHSIZE)+c_instr, $00FFD8A5

    lea     ch_state+CHSIZE, a6            ; explicit F2 note takes only F2 back
    clr.b   c_instr(a6)
    move.b  #60, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD8A6
    move.b  fmgrp_owner+2, $00FFD8A7
    lea     ch_state, a6                   ; next root note reclaims both
    move.b  #50, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD8A8
    move.b  fmgrp_owner+2, $00FFD8A9
    move.b  ch_state+CHSIZE+c_note, $00FFD8AA
    move.b  ch_state+(2*CHSIZE)+c_note, $00FFD8AB

    lea     $00FFD8E0, a1                  ; grouped C00 releases/key-offs both followers
    move.b  #$FF, (a1)
    clr.b   1(a1)
    move.b  #3, 2(a1)
    clr.b   3(a1)
    moveq   #0, d1
    bsr     exec_cmd
    move.b  fmgrp_chord, $00FFD8AC
    move.b  fmgrp_owner+1, $00FFD8AD
    move.b  fmgrp_owner+2, $00FFD8AE
    move.b  ch_state+CHSIZE+c_keyon, $00FFD8AF
    move.b  ch_state+(2*CHSIZE)+c_keyon, $00FFD8B0

    move.b  #$37, 3(a1)                    ; non-zero C reclaims an already sounding root
    bsr     exec_cmd
    move.b  fmgrp_owner+1, $00FFD8B1
    move.b  fmgrp_owner+2, $00FFD8B2
    move.b  ch_state+CHSIZE+c_note, $00FFD8B3
    move.b  ch_state+(2*CHSIZE)+c_note, $00FFD8B4
    move.b  #$70, 3(a1)                    ; zero low nibble mutes/releases only follower 2
    bsr     exec_cmd
    move.b  fmgrp_owner+1, $00FFD8B5
    move.b  fmgrp_owner+2, $00FFD8B6
    move.b  ch_state+CHSIZE+c_note, $00FFD8B7
    move.b  ch_state+(2*CHSIZE)+c_keyon, $00FFD8B8

    lea     ch_state+(4*CHSIZE), a6        ; F5 cannot lead: C remains its ordinary arpeggio
    clr.b   c_instr(a6)
    move.b  #48, c_note(a6)
    move.b  #$47, 3(a1)
    bsr     exec_cmd
    move.b  c_chord+4, $00FFD8B9
    move.b  fmgrp_owner+5, $00FFD8BA

    lea     ch_state, a6                   ; cold grouped trigger: all three complete patches fit one tick
    move.b  #$47, fmgrp_chord
    move.b  #48, c_note(a6)
    bsr     note_trigger
    move.b  #$FF, pshadow
    move.b  #$FF, pshadow+1
    move.b  #$FF, pshadow+2
    clr.b   patch_done
    clr.b   fm_keypend
    lea     ym_data, a5
    moveq   #0, d5
    lea     ch_state, a6
    bsr     compose_fm
    lea     ch_state+CHSIZE, a6
    bsr     compose_fm
    lea     ch_state+(2*CHSIZE), a6
    bsr     compose_fm
    bsr     flush_fm_keyons
    move.b  patch_done, $00FFD8BB
    move.b  ch_state+c_trig, $00FFD8BC
    move.b  ch_state+CHSIZE+c_trig, $00FFD8BD
    move.b  ch_state+(2*CHSIZE)+c_trig, $00FFD8BE
    move.b  d5, $00FFD8BF

    move.b  #SCR_INSTR, cur_screen         ; visual grid: HLD -> GROUP -> FSWP -> TSP
    clr.b   cur_instr
    move.b  #2, cur_row
    clr.b   cur_col
    moveq   #8, d2                         ; HLD + Right -> GROUP
    bsr     move_cursor
    move.b  cur_row, $00FFD8C0
    move.b  cur_col, $00FFD8C1
    moveq   #2, d2                         ; GROUP + Down -> FSWP
    bsr     move_cursor
    move.b  cur_row, $00FFD8C2
    move.b  cur_col, $00FFD8C3
    moveq   #2, d2                         ; FSWP + Down -> TSP
    bsr     move_cursor
    move.b  cur_row, $00FFD8C4
    move.b  cur_col, $00FFD8C5
    moveq   #1, d2                         ; TSP + Up -> FSWP
    bsr     move_cursor
    move.b  cur_row, $00FFD8C6
    move.b  cur_col, $00FFD8C7
    moveq   #1, d2                         ; FSWP + Up -> GROUP
    bsr     move_cursor
    move.b  cur_row, $00FFD8C8
    move.b  cur_col, $00FFD8C9
    moveq   #4, d2                         ; GROUP + Left -> HLD
    bsr     move_cursor
    move.b  cur_row, $00FFD8CA
    move.b  cur_col, $00FFD8CB
    move.b  #1, cur_row                    ; ROM LOAD + Down -> GROUP
    move.b  #5, cur_col
    moveq   #2, d2
    bsr     move_cursor
    move.b  cur_row, $00FFD8CC
    move.b  cur_col, $00FFD8CD
    moveq   #1, d2                         ; GROUP + Up -> ROM LOAD
    bsr     move_cursor
    move.b  cur_row, $00FFD8CE
    move.b  cur_col, $00FFD8CF
    move.b  #3, cur_row                    ; VOL + Right -> FSWP
    clr.b   cur_col
    moveq   #8, d2
    bsr     move_cursor
    move.b  cur_row, $00FFD8D0
    move.b  cur_col, $00FFD8D1

    lea     instrum, a0                    ; UNISON needs no C chord: same note, symmetric raw-FNUM spread
    move.b  #FMGRP_UNISON, (i_fgroup,a0)
    clr.b   fmgrp_chord
    lea     ch_state, a6
    move.b  #48, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD900
    move.b  fmgrp_owner+2, $00FFD901
    move.b  ch_state+CHSIZE+c_note, $00FFD902
    move.b  ch_state+(2*CHSIZE)+c_note, $00FFD903
    move.b  fmgrp_fine+1, $00FFD904
    move.b  fmgrp_fine+2, $00FFD905
    lea     $00FFD8E0, a1                  ; fixed modes keep Cxy as a synchronized ordinary arp
    move.b  #$FF, (a1)
    clr.b   1(a1)
    move.b  #3, 2(a1)
    move.b  #$37, 3(a1)
    moveq   #0, d1
    bsr     exec_cmd
    move.b  c_chord, $00FFD906
    move.b  c_chord+1, $00FFD907
    move.b  c_chord+2, $00FFD908
    lea     ch_state+CHSIZE, a6            ; an explicit follower note drops its detune and ownership
    move.b  #1, c_instr(a6)                ; instrument 1 is ordinary FM with GROUP=OFF
    move.b  #60, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD909
    move.b  fmgrp_fine+1, $00FFD90A
    move.b  fmgrp_owner+2, $00FFD90B
    move.b  fmgrp_fine+2, $00FFD90C

    lea     instrum, a0                    ; OCTAVE places the two followers above and below
    move.b  #FMGRP_OCTAVE, (i_fgroup,a0)
    lea     ch_state, a6
    move.b  #48, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD90D
    move.b  fmgrp_owner+2, $00FFD90E
    move.b  ch_state+CHSIZE+c_note, $00FFD90F
    move.b  ch_state+(2*CHSIZE)+c_note, $00FFD910
    move.b  fmgrp_fine+1, $00FFD911
    move.b  fmgrp_fine+2, $00FFD912

    move.b  #5, (i_fgroup,a0)              ; sanitizer rejects anything beyond the defined enum
    bsr     sanitize_fm_ssg_record
    move.b  (i_fgroup,a0), $00FFD913
    move.b  #FMGRP_POWER, (i_fgroup,a0)     ; but preserves POWER as a valid saved mode
    bsr     sanitize_fm_ssg_record
    move.b  (i_fgroup,a0), $00FFD914

    lea     instrum, a0                    ; POWER places followers at fifth and octave above
    move.b  #FMGRP_POWER, (i_fgroup,a0)
    lea     ch_state, a6
    move.b  #48, c_note(a6)
    bsr     note_trigger
    move.b  fmgrp_owner+1, $00FFD915
    move.b  fmgrp_owner+2, $00FFD916
    move.b  ch_state+CHSIZE+c_note, $00FFD917
    move.b  ch_state+(2*CHSIZE)+c_note, $00FFD918
    move.b  fmgrp_fine+1, $00FFD919
    move.b  fmgrp_fine+2, $00FFD91A

    move.b  #12, cur_row                   ; leave GROUP selected for the rendered-frame visual check
    move.b  #1, cur_col
    movem.l (sp)+, d0-d7/a0-a6
.tfgdone:
"""

# arm a tempo glide (4 -> 10 frames/row over SLID=2 bars) at frame 5
CONT_GLIDE_ARM = """    move.w  g_ticks, d0
    cmpi.w  #5, d0
    bne.s   .cgaskip
    move.b  #2, cont_slid
    move.b  #4, glide_from
    move.b  #10, glide_to
    bsr     cont_glide_start
.cgaskip:
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

def t_kit_retrigger():
    """R on a KIT voice restarts the DAC while its attenuation advances."""
    rom = build_rom('kit_retrigger', boot_inject=KIT_RETRIG_SONG,
                    frame_inject=DAC_TRIGGER_LOGGER)
    ram = run_rom(rom, 45)
    r = ring(ram)
    trig = [(x >> 8) & 0xFF for x in r]
    drop = [x & 0xFF for x in r]
    strikes = sum(1 for i in range(64) if ((trig[(i+1) % 64] - trig[i]) & 0xFF) == 1)
    assert strikes >= 4, 'R decay advanced but DAC only triggered %d times (%r)' % (strikes, trig)
    assert max(drop) >= 3, 'R attenuation did not advance with KIT strikes (%r)' % drop
    return '%d DAC re-strikes; attenuation reached %d' % (strikes, max(drop))

def t_kit_gain():
    """Pre-shifted KIT levels reduce amplitude without reducing Z80 feed cadence."""
    levels = []
    rates = []
    for mode in range(6):
        arm = KIT_GAIN_ARM.replace(
            '    move.b  #0, (i_gain,a1)\n',
            '    move.b  #%d, (i_gain,a1)\n' % mode)
        rom = build_rom('kit_gain_%d' % mode, boot_inject=arm,
                        frame_inject=FRAME_LOGGER_NOARM)
        ram = run_rom(rom, 90)
        r = ring(ram)
        diffs = [(r[(i+1) % 64] - r[i]) & 0xFF for i in range(64)]
        active = sorted(x for x in diffs if 100 < x < 250)
        if mode < 5:
            assert len(active) >= 10, 'mode %d stopped feeding (%r)' % (mode, diffs)
            rates.append(active[len(active)//2])

        with wave.open(rom + '.ppm.wav', 'rb') as wav:
            hz = wav.getframerate()
            raw = wav.readframes(wav.getnframes())
        pcm = struct.unpack('<%dh' % (len(raw)//2), raw)
        mono = [(pcm[i] + pcm[i+1]) / 2 for i in range(0, len(pcm), 2)]
        window = mono[int(hz*0.12):int(hz*0.36)]  # safely inside the long direct pad
        levels.append(math.sqrt(sum(x*x for x in window) / len(window)))

    assert levels[0] > 1000, 'full-volume probe unexpectedly quiet (RMS %.1f)' % levels[0]
    for mode in range(1, 5):
        ratio = levels[mode] / levels[mode-1]
        assert 0.40 <= ratio <= 0.65, 'mode %d ratio %.3f is not a half-step' % (mode, ratio)
    assert levels[5] < 1, 'mute produced non-zero audio (RMS %.1f)' % levels[5]
    assert all(165 <= x <= 185 for x in rates), 'gain changed feed cadence (%r)' % rates
    return 'RMS %s; feed %s/frame; mute silent' % (
        '/'.join(str(int(x)) for x in levels), '/'.join(str(x) for x in rates))

def t_kit_navigation():
    """KIT cursor visits VOL/RATE/TSP in order and VOL edits in musical directions."""
    rom = build_rom('kit_navigation', boot_inject=KIT_NAV)
    ram = run_rom(rom, 30)
    assert list(ram[0xD501:0xD506]) == [3, 4, 5, 0, 5], \
        'KIT row cycle wrong (%r)' % list(ram[0xD501:0xD506])
    assert list(ram[0xD506:0xD50C]) == [1, 0, 5, 4, 0, 1], \
        'KIT VOL directions/limits wrong (%r)' % list(ram[0xD506:0xD50C])
    assert list(ram[0xD50C:0xD50E]) == [2, 0], \
        'bank-to-KIT navigation did not land on KIT row/column 0 (%r)' % list(ram[0xD50C:0xD50E])
    return 'rows KIT→VOL→RATE→TSP wrap; VOL directions and bank exit correct'

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
    assert t6c == 0xFE, 'bridge sentinel not set (c_chain=$%02X)' % t6c
    assert 0xFFD790 <= t6ph < 0xFFD7D0, 'bridge c_phrase not in carry_buf ($%08X)' % t6ph
    assert t6ins == 31, 'bridge c_instr not the reserved slot (%d)' % t6ins
    assert t6vol > 0, 'bridge is silent (c_vol=%d)' % t6vol
    return 'T1 bridged (c_vol=%d, reads its private phrase)' % t6vol

def t_cont_quantize():
    """CONT: an armed swap holds until the carried voice's phrase downbeat, fires
    beat-quantized, then leaves only its private phrase playing in LIVE mode."""
    rom = build_rom('cont_quantize', boot_inject=CONT_LOAD_SONG, frame_inject=CONT_ARM)
    held = run_rom(rom, 60)
    assert held[0xD763] == 1, 'CONT fired before a downbeat (cont_pending cleared early)'
    fired = run_rom(rom, 220)
    assert fired[0xD763] == 0, 'CONT never fired (still armed at frame 220)'
    assert fired[0xE3E9] == 1, 'CONT did not force the loaded project into LIVE mode (%d)' % fired[0xE3E9]
    assert fired[0xE104] == 0xFE, 'carried T1 left its private bridge without a manual launch'
    assert fired[0xD76E] != 0xFF, 'carried T1 released its borrowed slot before a manual launch'
    assert fired[0xE014] == 0xFF, 'non-carried F1 auto-started from the target song (c_chain=$%02X)' % fired[0xE014]
    assert fired[0xE0F4] > 0, 'carried T1 bridge is silent (c_vol=%d)' % fired[0xE0F4]
    return 'armed, fired on a downbeat, forced LIVE, and retained only the carried bridge'

def t_cont_live_handover():
    """LIVE target clears stale tracks, borrows only an unused slot, and a queued
    same-row relaunch retires the bridge only after it has looped unqueued."""
    ram = run_rom(build_rom('cont_live_handover', boot_inject=CONT_LIVE_HANDOVER), 30)
    got = list(ram[0xD800:0xD808])
    assert got == [29, 6, 3, 4, 0, 0, 0xFF, 1], 'LIVE plant/stale-state results %r' % got
    assert list(ram[0xD808:0xD80D]) == [0xFE, 0, 0, 29, 0xFF], \
        'unqueued bridge did not keep looping privately: %r' % list(ram[0xD808:0xD80D])
    assert ram[0xD80D] == 2, 'same-row replacement was not armed for bridge end (%d)' % ram[0xD80D]
    got = list(ram[0xD80E:0xD814])
    assert got == [0, 0, 0, 0xFF, 5, 0xFF], 'manual LIVE bridge handoff results %r' % got
    return 'old phrase looped; same-row target launch restored slot 29 and replaced the bridge'

def t_cont_empty_target():
    """An empty target cannot implicitly stop a carried private phrase."""
    ram = run_rom(build_rom('cont_empty_target', boot_inject=CONT_EMPTY_TARGET), 30)
    got = list(ram[0xD800:0xD807])
    assert got == [0xFE, 0, 0, 1, 6, 0xFF, 4], 'empty-target bridge results %r' % got
    return 'empty target left the source phrase and patch bridged; target patch remains backed up'

def t_cont_no_free_slot():
    """A fully referenced target bank drops the bridge without corrupting a slot."""
    ram = run_rom(build_rom('cont_no_free_slot', boot_inject=CONT_NO_FREE_SLOT), 30)
    got = list(ram[0xD800:0xD804])
    assert got == [0xFF, 0xFF, 0, 4], 'full-bank fallback results %r' % got
    return 'all 32 referenced slots protected; bridge declined and target bank preserved'

def t_cont_multi_instr():
    """Every IN change in a bridge phrase keeps its own source patch."""
    ram = run_rom(build_rom('cont_multi_instr', boot_inject=CONT_MULTI_INSTR), 30)
    planted = list(ram[0xD501:0xD508])
    assert planted == [29, 28, 29, 6, 7, 0xFE, 1], \
        'multi-instrument bridge flattened/remapped incorrectly: %r' % planted
    restored = list(ram[0xD508:0xD50B])
    assert restored == [4, 5, 0], 'target patch bank was not restored atomically: %r' % restored
    return 'two row-level source patches stayed distinct; both target slots restored on retirement'

def t_cont_global_isolation():
    """Source modulation is bridge-only during overlap; target globals return afterward."""
    ram = run_rom(build_rom('cont_global_isolation', boot_inject=CONT_GLOBAL_ISOLATION), 30)
    active = list(ram[0xD520:0xD528])
    assert active == [1, 7, 0xFD, 5, 2, 0, 0, 0], \
        'source globals/echo isolation during overlap is wrong: %r' % active
    phase0 = int.from_bytes(ram[0xD528:0xD52A], 'big')
    phase1 = int.from_bytes(ram[0xD52A:0xD52C], 'big')
    ran0 = int.from_bytes(ram[0xD52C:0xD52E], 'big')
    ran1 = int.from_bytes(ram[0xD52E:0xD530], 'big')
    assert (phase0, phase1, ran0, ran1) == (0x1000, 0x2000, 0x1020, 0x2000), \
        'software LFOs crossed the bridge/target boundary: %r' % \
        ((phase0, phase1, ran0, ran1),)
    assert ram[0xD530] == 0, 'target echo still owned a channel during overlap'
    restored = list(ram[0xD531:0xD539])
    assert restored == [0, 2, 4, 8, 3, 1, 12, 0x55], \
        'target globals/LFO configuration did not return: %r' % restored
    assert int.from_bytes(ram[0xD53A:0xD53C], 'big') == 0, \
        'target LFO runtime phase was not reset on activation'
    assert ram[0xD53C] == 1, 'target echo did not reactivate after final bridge retirement'
    return 'source LFO/transpose/scale isolated; target LFO/echo restored at final retirement'

def t_live_contiguous():
    """A prior chain audition cannot trap a LIVE track on the first chain."""
    ram = run_rom(build_rom('live_contiguous', boot_inject=LIVE_CONTIGUOUS), 30)
    got = list(ram[0xD800:0xD804])
    assert got == [0, 1, 1, 0], 'LIVE contiguous block retained solo mode/stuck on row 0: %r' % got
    return 'chain audition cleared; LIVE advanced row 0/chain 0 -> row 1/chain 1'

def t_live_full_chain():
    """A full 16-step chain advances the arrangement but loops in chain-solo."""
    ram = run_rom(build_rom('live_full_chain', boot_inject=LIVE_FULL_CHAIN), 30)
    arranged = list(ram[0xD810:0xD813])
    solo = list(ram[0xD813:0xD816])
    song = list(ram[0xD816:0xD819])
    assert arranged == [1, 1, 0], 'full LIVE chain wrapped internally instead of advancing: %r' % arranged
    assert solo == [0, 0, 0], 'full chain did not retain chain-solo looping: %r' % solo
    assert song == [1, 1, 0], 'full SONG chain wrapped internally instead of advancing: %r' % song
    return 'full chain advances row 0->1 in LIVE/SONG and still loops in chain-solo'

def t_save_roundtrip():
    """SAVE commits a verified directory entry and LOAD restores the exact saved snapshot."""
    rom = build_rom('save_roundtrip', boot_inject=SAVE_ROUNDTRIP)
    ram = run_rom(rom, 60)
    assert ram[0xD501] == 0, 'save reported error %d' % ram[0xD501]
    assert ram[0xD502] == 0xA5, 'directory entry was not committed valid ($%02X)' % ram[0xD502]
    assert ram[0xD503] == 0x2A, 'round-trip restored $%02X, expected $2A' % ram[0xD503]
    assert ram[0xD504] == 1, 'validated load did not report success'
    assert ram[0xD505] == 0, 'load reported error %d' % ram[0xD505]
    return 'payload verified, entry committed, snapshot restored exactly'

def t_lfo_save_state():
    """Software-FM-LFO config is per-song; runtime phase is transient and loads are sanitized."""
    ram = run_rom(build_rom('lfo_save_state', boot_inject=LFO_SAVE_STATE), 240)
    assert list(ram[0xDD01:0xDD07]) == [0x15, 5, 34, 0xA7, 0x0D, 0x0E], \
        'LFO 0 did not survive save/load (%r)' % list(ram[0xDD01:0xDD07])
    assert list(ram[0xDD07:0xDD0D]) == [0x0B, 2, 7, 0x33, 4, 5], \
        'LFO F did not survive save/load (%r)' % list(ram[0xDD07:0xDD0D])
    assert list(ram[0xDD0D:0xDD11]) == [0, 0, 0, 1], \
        'LFO runtime phase/amp or load result incorrect (%r)' % list(ram[0xDD0D:0xDD11])
    assert ram[0xDD11] == 1, 'LFO-only edit was not detected as UNSAVED'
    assert list(ram[0xDD12:0xDD17]) == [0, 0, 0, 0, 0], \
        'legacy zero LFO block did not clear config/runtime (%r)' % list(ram[0xDD12:0xDD17])
    assert list(ram[0xDD17:0xDD1D]) == [7, 0, 0, 0xCC, 0x0F, 0x0F], \
        'loaded LFO fields were not sanitized (%r)' % list(ram[0xDD17:0xDD1D])
    assert list(ram[0xDD1D:0xDD20]) == [0, 0, 0] and ram[0xDD20] == 0, \
        'NEW project did not clear LFO config/runtime (%r, %d)' % (list(ram[0xDD1D:0xDD20]), ram[0xDD20])
    return '16 configs round-trip; legacy zeros, sanitization, dirty state and NEW reset verified'

def t_lfo_chain_sync():
    """CHAIN is a fourth LFO sync mode and resets only when the target enters chain step 0."""
    ram = run_rom(build_rom('lfo_chain_sync', boot_inject=LFO_CHAIN_SYNC), 40)
    assert list(ram[0xDD32:0xDD36]) == [0x55, 0x55, 0x20, 0x00], \
        'CHAIN mode responded to PHRASE or missed CHAIN reset (%r)' % list(ram[0xDD32:0xDD36])
    assert list(ram[0xDD36:0xDD39]) == [7, 1, 7], \
        'SYNC editor did not cycle FREE/CHAIN/NOTE correctly (%r)' % list(ram[0xDD36:0xDD39])
    assert list(ram[0xDD39:0xDD3C]) == [8, 0, 8], \
        'chain-start event incorrect for initial/interior/loop steps (%r)' % list(ram[0xDD39:0xDD3C])
    return 'CHAIN phase reset, four-way editor cycle, and step-0/loop events verified'

def t_load_bad_checksum():
    """A bad stored checksum leaves both the working song and its title untouched."""
    rom = build_rom('load_bad_checksum', boot_inject=LOAD_BAD_CHECKSUM)
    ram = run_rom(rom, 60)
    assert ram[0xD501] == 0x66, 'bad load changed current song byte to $%02X' % ram[0xD501]
    assert ram[0xD502] == ord('X'), 'bad load changed current title to $%02X' % ram[0xD502]
    assert ram[0xD503] == 0, 'bad load incorrectly reported success'
    assert ram[0xD504] == 1, 'bad load status %d != CHECKSUM BAD' % ram[0xD504]
    return 'checksum rejected; current song and title retained'

def t_load_bad_rle():
    """A truncated RLE stream is rejected in staging without touching the working song."""
    rom = build_rom('load_bad_rle', boot_inject=LOAD_BAD_RLE)
    ram = run_rom(rom, 60)
    assert ram[0xD501] == 0x77, 'malformed RLE changed current song byte to $%02X' % ram[0xD501]
    assert ram[0xD502] == 0, 'malformed RLE incorrectly reported success'
    assert ram[0xD503] == 1, 'malformed RLE status %d != CHECKSUM BAD' % ram[0xD503]
    return 'truncated RLE rejected before commit; current song retained'

def t_cont_bad_reload():
    """A rejected second CONT hop cannot overwrite an already-active bridge backup."""
    ram = run_rom(build_rom('cont_bad_reload', boot_inject=CONT_BAD_RELOAD), 90)
    got = list(ram[0xD100:0xD109])
    assert got == [0xFE, 0, 1, 30, 6, 4, 30, 0, 1], \
        'failed reload altered the active transition: %r' % got
    return 'bad target rejected before snapshot; active phrase, source patch, and target backup retained'

def t_save_freeze():
    """engine_tick performs no mutation while save/load has frozen the saved-data domain."""
    rom = build_rom('save_freeze', boot_inject=SAVE_FREEZE)
    ram = run_rom(rom, 60)
    assert ram[0xD501] == 0x55, 'engine_tick mutated state while save_busy ($%02X)' % ram[0xD501]
    return 'engine tick deferred before its first mutation'

def t_cursor_block():
    """SONG C+B starts on the exact cursor row, then loops to the contiguous block top."""
    rom = build_rom('cursor_block', boot_inject=CURSOR_BLOCK)
    ram = run_rom(rom, 30)
    assert ram[0xD501] == 1, 'started at row %d instead of cursor row 1' % ram[0xD501]
    assert ram[0xD502] == 1, 'started chain %d instead of row-1 chain 1' % ram[0xD502]
    assert ram[0xD503] == 0, 'block end looped to row %d instead of top row 0' % ram[0xD503]
    assert ram[0xD504] == 0, 'block loop loaded chain %d instead of row-0 chain 0' % ram[0xD504]
    return 'started at cursor row 1; block end looped to row 0'

def t_start_from_song_cursor():
    """Start/C+B use the SONG cursor and automatically wait when external sync is selected."""
    ram = run_rom(build_rom('start_from_song_cursor', boot_inject=START_FROM_SONG_CURSOR), 30)
    assert list(ram[0xD501:0xD506]) == [0x46, 0x46, 7, 1, 0], \
        'SONG Start row/chain or stop state incorrect (%r)' % list(ram[0xD501:0xD506])
    assert list(ram[0xD506:0xD509]) == [0x46, 1, 0x46], \
        'external-sync Start did not arm at row 46 (%r)' % list(ram[0xD506:0xD509])
    assert list(ram[0xD509:0xD50C]) == [0x46, 1, 0x46], \
        'external-sync C+B did not arm at row 46 (%r)' % list(ram[0xD509:0xD50C])
    assert ram[0xD50C] == 0, 'Start outside SONG retained row $%02X instead of row 0' % ram[0xD50C]
    return 'Start/C+B launch row 46 and auto-arm external WAIT; other screens launch row 0'

def t_phrase_iteration():
    """Normal SONG phrase wraps advance I/J play counts; IAA gates alternate passes."""
    ram = run_rom(build_rom('phrase_iteration', boot_inject=PHRASE_ITERATION), 30)
    got = list(ram[0xD501:0xD509])
    assert got == [1, 40, 2, 48, 3, 40, 4, 48], \
        'SONG IAA repeat count/gate sequence incorrect (%r)' % got
    assert ram[0xD509] == 0, \
        'CONT private-phrase wrap changed a pooled phrase counter (%d)' % ram[0xD509]
    return 'SONG counts 1-4; IAA is off/on/off/on; CONT private wrap remains isolated'

def t_deep_clone_aliases():
    """DEEP clones each unique phrase once while preserving repeated references and transposes."""
    rom = build_rom('deep_clone_aliases', boot_inject=DEEP_CLONE_ALIASES)
    ram = run_rom(rom, 60)
    assert ram[0xD501] == 2, 'preflight counted %d phrases instead of 2 unique references' % ram[0xD501]
    refs = list(ram[0xD502:0xD506])
    assert refs == [2, 3, 2, 2], 'clone did not preserve source aliases (%r)' % refs
    transposes = list(ram[0xD506:0xD50A])
    assert transposes == [0, 0x0C, 0xF4, 7], 'row transposes changed (%r)' % transposes
    assert ram[0xD50A] == 40 and ram[0xD50B] == 41, 'unique phrase contents were not copied'
    assert ram[0xD50C] == 40, 'editing the clone changed its source phrase'
    return '2 unique copies; alias pattern and four row transposes preserved'

def t_paste_and_mint():
    """C,C pastes; B,B still clones even with a populated clipboard; C chords are filtered."""
    ram = run_rom(build_rom('paste_and_mint', boot_inject=PASTE_AND_MINT), 40)
    assert ram[0xD501] == 37, 'clean C,C did not paste (%d)' % ram[0xD501]
    assert ram[0xD502] == 6, 'B,B pasted clipboard or failed to clone (song=%d)' % ram[0xD502]
    assert ram[0xD503] == 0, 'cloned chain content missing (%d)' % ram[0xD503]
    assert ram[0xD504] == 0, 'C chord was incorrectly recorded as a clean paste tap'
    return 'clean C,C pastes; B,B clones; C chords ignored'

def t_song_page_addressing():
    """SONG edits and drill-down use absolute pages; block pastes stop at data bounds."""
    ram = run_rom(build_rom('song_page_addressing', boot_inject=SONG_PAGE_ADDRESSING), 40)
    assert list(ram[0xD501:0xD505]) == [0x11, 1, 0x06, 0xFF], \
        'later-page edit/cut addressed the wrong cells (%r)' % list(ram[0xD501:0xD505])
    assert list(ram[0xD505:0xD508]) == [0x46, 5, 6], \
        'drill-down/channel context lost the absolute SONG row (%r)' % list(ram[0xD505:0xD508])
    assert list(ram[0xD508:0xD50D]) == [0xA1, 0xA2, 0x5A, 0xB1, 0x5B], \
        'SONG/phrase paste crossed a data boundary (%r)' % list(ram[0xD508:0xD50D])
    assert list(ram[0xD50D:0xD511]) == [2, 0, 2, 15], \
        'SONG selection escaped its page (%r)' % list(ram[0xD50D:0xD511])
    return 'page edits/cuts isolated; row 46 context retained; SONG/phrase paste bounds protected'

def t_song_structural_edit():
    """SONG gap-close/insert are absolute, column-scoped and refuse destructive boundaries."""
    ram = run_rom(build_rom('song_structural_edit', boot_inject=SONG_STRUCTURAL_EDIT), 40)
    assert list(ram[0xD501:0xD505]) == [0x22, 0x33, 0xFF, 0x7A], \
        'single-track close-gap/page/clipboard result incorrect (%r)' % list(ram[0xD501:0xD505])
    assert list(ram[0xD505:0xD50B]) == [0x41, 0x42, 0x51, 0x52, 0x6A, 0], \
        'selected close-gap did not preserve rectangle/other track (%r)' % list(ram[0xD505:0xD50B])
    assert list(ram[0xD50B:0xD511]) == [0xA1, 0xA2, 0x61, 0x62, 0x63, 0x66], \
        'clipboard insertion/order/column isolation incorrect (%r)' % list(ram[0xD50B:0xD511])
    assert list(ram[0xD511:0xD514]) == [2, 0xA1, 0xEE], \
        'NO ROOM did not preserve destination/tail transactionally (%r)' % list(ram[0xD511:0xD514])
    assert list(ram[0xD514:0xD517]) == [1, 0xA1, 3], \
        'CUT FIRST/NO CLIP refusal status or data preservation incorrect (%r)' % list(ram[0xD514:0xD517])
    assert list(ram[0xD517:0xD519]) == [0, 1], \
        'structural-edit warning did not expire and request redraw (%r)' % list(ram[0xD517:0xD519])
    assert list(ram[0xD519:0xD51F]) == [0x10, 0x19, 0xC0, 0xC9, 0x01, 0x09], \
        'full-width close/insert zero-stride path incorrect (%r)' % list(ram[0xD519:0xD51F])
    return 'page-aware gap close; block/column shift; atomic insert; refusal statuses'

def t_reference_edit():
    """Reference edits remain unsigned through $80..$BF and clamp at their true ceilings."""
    ram = run_rom(build_rom('reference_edit', boot_inject=REFERENCE_EDIT), 35)
    got = list(ram[0xD501:0xD507])
    assert got == [0x81, 0xBF, 0xBE, 0, 0x7F, 0], 'reference edit results %r' % got
    return '$80 increments; $BF/$7F clamp; empty and transpose sentinel behavior retained'

def t_cyclic_alloc():
    """Allocation searches upward with wrap and never takes a referenced empty record."""
    ram = run_rom(build_rom('cyclic_alloc', boot_inject=CYCLIC_ALLOC), 35)
    got = list(ram[0xD501:0xD505])
    assert got == [32, 0, 32, 0], 'cyclic/reference-aware allocation %r' % got
    return 'chain/phrase upward search wraps and skips referenced-empty slot 31'

def t_files_confirm():
    """Every FILES action does nothing on the first tap and executes on the second."""
    ram = run_rom(build_rom('files_confirm', boot_inject=FILES_CONFIRM), 70)
    got = list(ram[0xD800:0xD808])
    assert got == [0x11, 0x55, 0xFF, 0x10, 0, 1, 1, 0], 'FILES confirmation sequence %r' % got
    purges = list(ram[0xD808:0xD80C])
    assert purges == [60, 0xFF, 0, 0xFF], 'purge confirmation sequence %r' % purges
    return 'SAVE/LOAD/CLEAR/PURGE PHRASE/PURGE CHAIN arm first, execute second'

def t_files_confirm_cancel():
    """FILES confirmation lifetime and safe session-only action cursor behavior."""
    ram = run_rom(build_rom('files_confirm_cancel', boot_inject=FILES_CONFIRM_CANCEL), 35)
    got = list(ram[0xD800:0xD804])
    assert got == [0, 1, 0, 0], 'FILES confirmation cancel/expiry %r' % got
    state = list(ram[0xD804:0xD808])
    assert state == [5, 0, 2, 1], 'FILES initial/remembered cursor state %r' % state
    return 'timeout/nav/close cancel SURE?; first open is CANCEL; later opens remember the action'

def t_files_title():
    """FILES renders the currently loaded eight-character song title in its first row."""
    rom = build_rom('files_title', boot_inject=FILES_TITLE)
    ram = run_rom(rom, 150)
    assert ram[0xE20B] == 12, 'test did not remain on FILES (screen %d)' % ram[0xE20B]
    assert bytes(ram[0xD3B0:0xD3B8]) == b'TESTSONG', \
        'working song title changed unexpectedly (%r)' % bytes(ram[0xD3B0:0xD3B8])
    ppm = open(rom + '.ppm', 'rb').read()
    body = ppm.split(b'\n', 3)[3]
    lit = 0
    for y in range(8, 16):                  # tile row 1
        for x in range(14*8, 22*8):         # cols 14..21, the eight title cells
            px = body[(y*320+x)*3:(y*320+x+1)*3]
            lit += any(c > 32 for c in px)
    assert lit > 40, 'FILES title area is blank (%d lit pixels)' % lit
    return 'FILES row 1 rendered TESTSONG (%d lit pixels)' % lit

def t_fm_simultaneous():
    """Warm patch shadows survive transport reset; cold F1/F2 prepare in one SCB with adjacent keys."""
    ram = run_rom(build_rom('fm_simultaneous', boot_inject=FM_SIMULTANEOUS), 35)
    assert list(ram[0xD800:0xD803]) == [3, 4, 0], \
        'warm patch shadows/repatch state %r' % list(ram[0xD800:0xD803])
    cold = list(ram[0xD803:0xD80D])
    assert cold == [80, 0, 0, 2, 0, 0x28, 0xF0, 0, 0x28, 0xF1], \
        'cold simultaneous FM queue %r' % cold
    warm = list(ram[0xD80D:0xD815])
    assert warm == [20, 0, 0, 0x28, 0xF0, 0, 0x28, 0xF1], \
        'warm simultaneous FM queue %r' % warm
    return 'transport preserves patches; cold F1/F2 share 80-write SCB; warm pair uses 20; keys adjacent'

def t_fm_ssg_eg():
    """SSG-EG storage/editor plus the type-safe, per-channel S command and restoration path."""
    ram = run_rom(build_rom('fm_ssg_eg', boot_inject=FM_SSG_EG), 35)
    assert list(ram[0xD821:0xD825]) == [0x81, 0xA0, 0xF1, 0], \
        'packed AM/SSG sanitization %r' % list(ram[0xD821:0xD825])
    assert list(ram[0xD825:0xD829]) == [0x81, 0x01, 0xA1, 10], \
        'SSG/AM editor independence or column bound %r' % list(ram[0xD825:0xD829])
    emitted = list(ram[0xD829:0xD834])
    assert emitted == [30, 0x60, 0x85, 0x90, 8, 0x94, 0x0A, 0x98, 0x0F, 0x9C, 0], \
        'channel patch SSG register stream %r' % emitted
    built = list(ram[0xD834:0xD83D])
    assert built == [30, 0x90, 8, 0x94, 0x0A, 0x98, 0x0F, 0x9C, 0], \
        'boot/editor patch SSG register stream %r' % built
    assert list(ram[0xD83D:0xD841]) == [5, 8, 5, 1], \
        'FM S58 did not arm mask/mode/dirty state %r' % list(ram[0xD83D:0xD841])
    assert list(ram[0xD841:0xD849]) == [2, 0, 0x90, 8, 0, 0x94, 8, 0], \
        'FM S58 logical operator routing/write stream %r' % list(ram[0xD841:0xD849])
    assert list(ram[0xD849:0xD84D]) == [5, 8, 0, 0], \
        'reserved FM S shape was not ignored %r' % list(ram[0xD849:0xD84D])
    assert list(ram[0xD84D:0xD850]) == [3, 5, 0], \
        'KIT S dispatch changed FM state or lost sample rate %r' % list(ram[0xD84D:0xD850])
    assert list(ram[0xD850:0xD852]) == [5, 0], \
        'FM S command leaked onto a PSG hardware channel %r' % list(ram[0xD850:0xD852])
    restored = list(ram[0xD852:0xD85F])
    assert restored == [4, 0, 0x90, 8, 0, 0x94, 0x0A, 0, 0x98, 0x0F, 0, 0x9C, 0], \
        'FM S override restoration stream %r' % restored
    return 'stored SSG + editor; S mask routing; type guards; reserved rejection; next-note restoration'

def t_fm_fnum_sweep():
    """FM/PERC SWEEP targets octave C, uses raw F-number, and preserves packed XY timing."""
    ram = run_rom(build_rom('fm_fnum_sweep', boot_inject=FM_FNUM_SWEEP), 35)
    got = list(ram[0xD861:0xD87B])
    expect = [16, 0x23, 0x84, 14, 0x23, 0x64, 12, 12,
              0x23, 0x84, 0x1B, 0x84, 0x33, 0x84, 0x0B, 0x84, 14,
              0x80, 0x22, 0x84, 0, 0x24, 0xBF, 0x22, 0x84, 0]
    assert got == expect, 'raw F-number sweep results %r' % got
    return 'pitch class ignored; $42 descends; $30 holds; $1F lands; PERC keeps blocks; $00 stays pitched'

def t_fm_fswp_command():
    """Bxy overrides FSWP only for compatible FM/PERC instruments and preserves WAVE B."""
    ram = run_rom(build_rom('fm_fswp_command', boot_inject=FM_FSWP_COMMAND), 35)
    got = list(ram[0xD880:0xD89B])
    expect = [0x13, 0, 1, 1, 4, 0x22, 0xC4, 1,
              0, 0, 1, 1, 0x80, 0x24, 0xBF, 0,
              0x42, 0, 0, 0x0A, 0, 0,
              0x24, 4, 1, 0, 0]
    assert got == expect, 'Bxy FSWP/type-routing results %r' % got
    return 'FM override/disable/restore; WAVE bank retained; PERC F3-only guard'

def t_fm_prewarm():
    """Stopped-load prediction scans first chains, warms three FM patches per pass, and cancels on start."""
    ram = run_rom(build_rom('fm_prewarm', boot_inject=FM_PREWARM), 35)
    assert list(ram[0xD800:0xD807]) == [0x3F, 0, 1, 2, 3, 4, 5], \
        'FM prewarm plan %r' % list(ram[0xD800:0xD807])
    assert list(ram[0xD807:0xD811]) == [0x38, 90, 0, 1, 0, 90, 0, 0, 4, 5], \
        'FM prewarm pacing/shadows %r' % list(ram[0xD807:0xD811])
    assert ram[0xD811] == 0x3B, 'FM audition did not consume track F3 prediction ($%02X)' % ram[0xD811]
    assert ram[0xD812] == 0, 'playback start did not cancel pending prewarm ($%02X)' % ram[0xD812]
    return 'first-chain prediction; three patches/frame; FM audition consumes its channel; playback cancels rest'

def t_cut_primes_insert():
    """Single-cell cuts prime the corresponding next-insert memory before clearing."""
    ram = run_rom(build_rom('cut_primes_insert', boot_inject=CUT_PRIMES_INSERT), 45)
    got = list(ram[0xD800:0xD80F])
    expect = [0xFF, 12, 12, 0xFF, 0x82, 0x82, 55, 55, 7, 4, 0xAB, 4, 0xAB, 0x3C, 66]
    assert got == expect, 'cut-to-prime results %r' % got
    return 'chain/phrase/note/instrument/command+parameter prime next insert; empty cut preserves memory'

def t_group_ownership():
    """GROUP ownership is per slave and follows explicit note/C-command transitions."""
    ram = run_rom(build_rom('group_ownership', boot_inject=GROUP_OWNERSHIP), 35)
    masks = list(ram[0xD501:0xD506])
    assert masks == [3, 2, 0, 3, 0], 'GROUP note ownership transitions %r' % masks
    t2_period = int.from_bytes(ram[0xD506:0xD508], 'big')
    t3_period = int.from_bytes(ram[0xD508:0xD50A], 'big')
    assert (t2_period, ram[0xD50A]) == (333, 5), \
        'released T2 was still overridden (%d, atten %d)' % (t2_period, ram[0xD50A])
    assert (t3_period, ram[0xD50B]) == (267, 0), \
        'still-owned T3 was not chord-derived (%d, atten %d)' % (t3_period, ram[0xD50B])
    commands = list(ram[0xD50C:0xD511])
    assert commands == [3, 0x80, 0, 3, 2], 'GROUP C00/reclaim/same-row priority %r' % commands
    return 'per-slave release; C00 release; later T1 reclaim; same-row slave priority'

def t_fm_group_ownership():
    """FM GROUP fans Cxy into the next two physical voices with PSG-style ownership."""
    ram = run_rom(build_rom('fm_group_ownership', boot_inject=FM_GROUP_OWNERSHIP), 40)
    assert list(ram[0xD8A0:0xD8A6]) == [1, 1, 52, 55, 0, 0], \
        'FM GROUP initial cascade %r' % list(ram[0xD8A0:0xD8A6])
    assert list(ram[0xD8A6:0xD8AC]) == [0, 1, 1, 1, 54, 57], \
        'FM GROUP follower release/reclaim %r' % list(ram[0xD8A6:0xD8AC])
    assert list(ram[0xD8AC:0xD8B1]) == [0, 0, 0, 0, 0], \
        'FM GROUP C00 release %r' % list(ram[0xD8AC:0xD8B1])
    assert list(ram[0xD8B1:0xD8B9]) == [1, 1, 53, 57, 1, 0, 57, 0], \
        'FM GROUP C37/C70 behavior %r' % list(ram[0xD8B1:0xD8B9])
    assert list(ram[0xD8B9:0xD8BB]) == [0x47, 0], \
        'FM GROUP F5 type/range guard %r' % list(ram[0xD8B9:0xD8BB])
    burst = list(ram[0xD8BB:0xD8C0])
    assert burst[0:4] == [3, 0, 0, 0], 'FM GROUP cold patch burst deferred a voice %r' % burst
    assert burst[4] <= 139, 'FM GROUP burst exceeded per-frame YM drain budget (%d)' % burst[4]
    nav = list(ram[0xD8C0:0xD8D2])
    assert nav == [12, 1, 12, 0, 5, 0, 12, 0, 12, 1, 2, 0, 12, 1, 1, 5, 12, 0], \
        'FM GROUP visual navigation wrong %r' % nav
    assert list(ram[0xD900:0xD906]) == [1, 1, 48, 48, 0xFE, 2], \
        'FM GROUP UNISON note/detune spread wrong %r' % list(ram[0xD900:0xD906])
    assert list(ram[0xD906:0xD909]) == [0x37, 0x37, 0x37], \
        'FM GROUP fixed-mode C arp was not copied %r' % list(ram[0xD906:0xD909])
    assert list(ram[0xD909:0xD90D]) == [0, 0, 1, 2], \
        'FM GROUP explicit UNISON follower release wrong %r' % list(ram[0xD909:0xD90D])
    assert list(ram[0xD90D:0xD913]) == [1, 1, 60, 36, 0, 0], \
        'FM GROUP OCTAVE voicing wrong %r' % list(ram[0xD90D:0xD913])
    assert list(ram[0xD913:0xD915]) == [0, 4], \
        'FM GROUP mode sanitizer wrong %r' % list(ram[0xD913:0xD915])
    assert list(ram[0xD915:0xD91B]) == [1, 1, 55, 60, 0, 0], \
        'FM GROUP POWER voicing wrong %r' % list(ram[0xD915:0xD91B])
    return 'CHORD ownership; UNISON +/-2; OCTAVE +/-12; POWER +7/+12; C sync; vertical GROUP navigation'

def t_cont_glide():
    """CONT: the tempo glide selects a scratch groove, ramps it old->new per bar, then hands
    back to the real groove (genmddj is groove-as-tempo, so tempo IS the scratch groove)."""
    rom = build_rom('cont_glide', boot_inject=STRESS_SONG, frame_inject=CONT_GLIDE_ARM)
    armed = run_rom(rom, 40)
    assert armed[0xD420] == 16, 'glide did not select the scratch groove (groove_sel=%d)' % armed[0xD420]
    assert armed[0xD778] == 4, 'scratch groove not seeded with the old tempo (%d)' % armed[0xD778]
    done = run_rom(rom, 260)
    assert done[0xD420] != 16, 'glide never handed back (groove_sel still 16)'
    assert done[0xD772] == 0, 'glide_left not drained (%d)' % done[0xD772]
    return 'scratch armed at 4 f/row, ramped, handed off after SLID bars'

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
    assert ram[0xD762] == 4, 'CONT SLID boot default %d != 4' % ram[0xD762]
    return 'boot renders SONG (%d lit probes); CONT SLID defaults to 4 bars' % lit

TESTS = [
    ('boot_smoke',   t_boot_smoke),
    ('save_roundtrip', t_save_roundtrip),
    ('lfo_save_state', t_lfo_save_state),
    ('lfo_chain_sync', t_lfo_chain_sync),
    ('save_freeze', t_save_freeze),
    ('load_bad_checksum', t_load_bad_checksum),
    ('load_bad_rle', t_load_bad_rle),
    ('cont_bad_reload', t_cont_bad_reload),
    ('cursor_block', t_cursor_block),
    ('start_from_song_cursor', t_start_from_song_cursor),
    ('phrase_iteration', t_phrase_iteration),
    ('deep_clone_aliases', t_deep_clone_aliases),
    ('paste_and_mint', t_paste_and_mint),
    ('song_page_addressing', t_song_page_addressing),
    ('song_structural_edit', t_song_structural_edit),
    ('reference_edit', t_reference_edit),
    ('cyclic_alloc', t_cyclic_alloc),
    ('files_confirm', t_files_confirm),
    ('files_confirm_cancel', t_files_confirm_cancel),
    ('files_title', t_files_title),
    ('fm_ssg_eg', t_fm_ssg_eg),
    ('fm_fnum_sweep', t_fm_fnum_sweep),
    ('fm_fswp_command', t_fm_fswp_command),
    ('fm_simultaneous', t_fm_simultaneous),
    ('fm_prewarm', t_fm_prewarm),
    ('cut_primes_insert', t_cut_primes_insert),
    ('group_ownership', t_group_ownership),
    ('fm_group_ownership', t_fm_group_ownership),
    ('dac_rate',     t_dac_rate),
    ('kit_endstop',  t_kit_endstop),
    ('kit_retrigger', t_kit_retrigger),
    ('kit_gain',     t_kit_gain),
    ('kit_navigation', t_kit_navigation),
    ('scb_delivery', t_scb_delivery),
    ('cont_bridge',  t_cont_bridge),
    ('cont_quantize', t_cont_quantize),
    ('cont_live_handover', t_cont_live_handover),
    ('cont_empty_target', t_cont_empty_target),
    ('cont_no_free_slot', t_cont_no_free_slot),
    ('cont_multi_instr', t_cont_multi_instr),
    ('cont_global_isolation', t_cont_global_isolation),
    ('cont_glide',   t_cont_glide),
    ('live_contiguous', t_live_contiguous),
    ('live_full_chain', t_live_full_chain),
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
