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
    movem.l (sp)+, d0-d7/a0-a6
.tfccdone:
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
    """CONT: an armed swap HOLDS until the carried voice's phrase downbeat, then fires
    (beat-quantized) -- not the instant LOAD is pressed."""
    rom = build_rom('cont_quantize', boot_inject=CONT_LOAD_SONG, frame_inject=CONT_ARM)
    held = run_rom(rom, 60)
    assert held[0xD763] == 1, 'CONT fired before a downbeat (cont_pending cleared early)'
    fired = run_rom(rom, 220)
    assert fired[0xD763] == 0, 'CONT never fired (still armed at frame 220)'
    assert fired[0xE104] == 0xFE, 'fired but did not plant the bridge (c_chain=$%02X)' % fired[0xE104]
    # SONG mode: the non-carried F1 (track 0) is RESTARTED on the new song, not silenced
    assert fired[0xE014] != 0xFF, 'non-carried F1 silenced in SONG mode (should restart, c_chain=$%02X)' % fired[0xE014]
    return 'armed, held past frame 60, fired on a downbeat; F1 restarted (SONG entry)'

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
    """FILES confirmation state expires autonomously and navigation cancels it."""
    ram = run_rom(build_rom('files_confirm_cancel', boot_inject=FILES_CONFIRM_CANCEL), 35)
    got = list(ram[0xD800:0xD804])
    assert got == [0, 1, 0, 0], 'FILES confirmation cancel/expiry %r' % got
    return 'timeout requests a repaint; moving actions cancels the armed confirmation'

def t_fm_simultaneous():
    """Warm patch shadows survive transport reset; cold F1/F2 prepare in one SCB with adjacent keys."""
    ram = run_rom(build_rom('fm_simultaneous', boot_inject=FM_SIMULTANEOUS), 35)
    assert list(ram[0xD800:0xD803]) == [3, 4, 0], \
        'warm patch shadows/repatch state %r' % list(ram[0xD800:0xD803])
    cold = list(ram[0xD803:0xD80D])
    assert cold == [72, 0, 0, 2, 0, 0x28, 0xF0, 0, 0x28, 0xF1], \
        'cold simultaneous FM queue %r' % cold
    warm = list(ram[0xD80D:0xD815])
    assert warm == [20, 0, 0, 0x28, 0xF0, 0, 0x28, 0xF1], \
        'warm simultaneous FM queue %r' % warm
    return 'transport preserves patches; cold F1/F2 share 72-write SCB; warm pair uses 20; keys adjacent'

def t_fm_prewarm():
    """Stopped-load prediction scans first chains, warms two FM patches per pass, and cancels on start."""
    ram = run_rom(build_rom('fm_prewarm', boot_inject=FM_PREWARM), 35)
    assert list(ram[0xD800:0xD807]) == [0x3F, 0, 1, 2, 3, 4, 5], \
        'FM prewarm plan %r' % list(ram[0xD800:0xD807])
    assert list(ram[0xD807:0xD811]) == [0x3C, 52, 0, 1, 0x30, 52, 0, 52, 4, 5], \
        'FM prewarm pacing/shadows %r' % list(ram[0xD807:0xD811])
    assert ram[0xD811] == 0x3B, 'FM audition did not consume track F3 prediction ($%02X)' % ram[0xD811]
    assert ram[0xD812] == 0, 'playback start did not cancel pending prewarm ($%02X)' % ram[0xD812]
    return 'first-chain prediction; two patches/frame; FM audition consumes its channel; playback cancels rest'

def t_cut_primes_insert():
    """Single-cell cuts prime the corresponding next-insert memory before clearing."""
    ram = run_rom(build_rom('cut_primes_insert', boot_inject=CUT_PRIMES_INSERT), 45)
    got = list(ram[0xD800:0xD80F])
    expect = [0xFF, 12, 12, 0xFF, 0x82, 0x82, 55, 55, 7, 4, 0xAB, 4, 0xAB, 0x3C, 66]
    assert got == expect, 'cut-to-prime results %r' % got
    return 'chain/phrase/note/instrument/command+parameter prime next insert; empty cut preserves memory'

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
    return 'boot renders SONG (%d lit probes)' % lit

TESTS = [
    ('boot_smoke',   t_boot_smoke),
    ('save_roundtrip', t_save_roundtrip),
    ('save_freeze', t_save_freeze),
    ('load_bad_checksum', t_load_bad_checksum),
    ('load_bad_rle', t_load_bad_rle),
    ('cursor_block', t_cursor_block),
    ('deep_clone_aliases', t_deep_clone_aliases),
    ('paste_and_mint', t_paste_and_mint),
    ('reference_edit', t_reference_edit),
    ('cyclic_alloc', t_cyclic_alloc),
    ('files_confirm', t_files_confirm),
    ('files_confirm_cancel', t_files_confirm_cancel),
    ('fm_simultaneous', t_fm_simultaneous),
    ('fm_prewarm', t_fm_prewarm),
    ('cut_primes_insert', t_cut_primes_insert),
    ('dac_rate',     t_dac_rate),
    ('kit_endstop',  t_kit_endstop),
    ('kit_gain',     t_kit_gain),
    ('kit_navigation', t_kit_navigation),
    ('scb_delivery', t_scb_delivery),
    ('cont_bridge',  t_cont_bridge),
    ('cont_quantize', t_cont_quantize),
    ('cont_glide',   t_cont_glide),
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
