; ============================================================
; genmddj - M5-A: multi-voice PSG engine
;
; The engine is now an array of channel structs (3 PSG squares),
; each playing its own phrase from a phrases pool, sharing a global
; groove. Per tick: global groove -> each channel advances its row
; + triggers -> per-channel AHD envelope -> compose one SCB with all
; channels' changed PSG writes -> push to the Z80. The PHRASE editor
; (M4) edits phrase 0, played live on channel 0.
; ============================================================

VDP_DATA   equ $C00000
VDP_CTRL   equ $C00004
Z80_RAM    equ $A00000
Z80_BUSREQ equ $A11100
Z80_RESET  equ $A11200
TMSS_REG   equ $A14000
VERSION    equ $A10001
IO_DATA1   equ $A10003
IO_CTRL1   equ $A10009

    include "build/splash.i"       ; SPLASH_W / SPLASH_H / SPLASH_NTILES
    include "build/algos.i"        ; ALGO_W / ALGO_H / ALGO_NTILES / ALGO_MAPSZ

; ---- channel struct ----
NCH        equ 10                  ; F1-F6 (FM) + T1-T3 (square) + NO (noise)
CHSIZE     equ 34                  ; even (keeps the long c_phrase word-aligned)
ch_state   equ $00FFE000           ; NCH * CHSIZE = 340 bytes ($FFE000-$FFE154)
c_note     equ 0
c_period   equ 2                    ; word
c_vol      equ 4
c_estate   equ 5
c_ectr     equ 6
c_row      equ 7                    ; phrase row 0-15
c_shadowp  equ 8                    ; word
c_shadowa  equ 10
c_psgt     equ 11                   ; PSG tone-latch base ($80/$A0/$C0)
c_psgv     equ 12                   ; PSG volume base ($90/$B0/$D0)
c_phrase   equ 16                   ; long: current phrase ptr (cached from chain)
c_chain    equ 20                   ; current chain (from song[songpos][track])
c_cstep    equ 21                   ; chain step 0-15 ($FF = pre-start)
c_transp   equ 22                   ; transpose of current chain step (signed)
c_track    equ 23                   ; song column for this channel (0..NCH-1)
c_songpos  equ 24                   ; current song row for this channel
c_type     equ 25                   ; 0 = PSG square, 1 = FM, 2 = PSG noise
c_ympart   equ 26                   ; FM: YM port part (0 = $4000/1, 1 = $4002/3)
c_ymchreg  equ 27                   ; FM: channel reg offset 0-2 (for $A0/$A4/$B0...)
c_ymkey    equ 28                   ; FM: $28 channel-select nibble (0-2, 4-6)
c_trig     equ 29                   ; FM: 1 = retrigger (key-off, freq, key-on) this tick
c_keyon    equ 30                   ; FM: desired key state
c_kshadow  equ 31                   ; FM: last key state sent to the chip
c_hold     equ 32                   ; gate countdown: $FF = held, else ticks until key-off

; ---- globals / cursor / scb ---- (relocated above the 10-channel array)
g_gctr     equ $00FFE200
g_seq      equ $00FFE201
cur_row    equ $00FFE202
cur_col    equ $00FFE203
key_prev   equ $00FFE204
key_rpt    equ $00FFE205
dpad_prev  equ $00FFE206
last_note  equ $00FFE207
e_audnote  equ $00FFE208
cur_phrase equ $00FFE209
playing    equ $00FFE20A           ; 0 = stopped, 1 = playing
cur_screen equ $00FFE20B           ; screen ID (see SCR_*); nav uses scr_order/scr_pos
cur_chain  equ $00FFE20C           ; chain shown/edited on the CHAIN screen
need_clear equ $00FFE20D           ; 1 = clear grid + redraw header next frame
play_row   equ $00FFE20E           ; playhead row for the current screen ($FF = none)
cur_instr  equ $00FFE20F           ; instrument shown/edited on the INSTRUMENT screen
cur_chan   equ $00FFE210           ; editing context: current channel (0..NCH-1)
cur_songrow equ $00FFE211          ; editing context: song row drilled from
g_ticks    equ $00FFE212           ; VBlank tick counter (word) for the top-right readout
play_mode  equ $00FFE214           ; 0 = full song, 1 = chain-solo, 2 = phrase-solo
play_from  equ $00FFE215           ; song row to start from (full-song mode)
in_splash  equ $00FFE216           ; 1 = showing the power-up splash
splash_ctr equ $00FFE218           ; splash countdown (word)
vdirty     equ $00FFE21A           ; 1 = input changed the grid; redraw needed
eng_adv    equ $00FFE21B           ; 1 = engine advanced a step; redraw the playhead
splash_row equ $00FFE21C           ; splash incremental-draw progress (0..SPLASH_H+1)
g_lfo      equ $00FFE21D           ; global FM LFO: 0 = off, 1-8 = on at rate 0-7
env_dirty  equ $00FFE21E           ; 1 = envelope needs rasterising (UI changed)
env_ready  equ $00FFE21F           ; 1 = env_canvas rasterised, upload in progress
last_cmd   equ $00FFE3A0           ; PHRASE C-column memory: last command entered (B-tap repeats it)
scr_row    equ $00FFE3A1           ; saved cursor row per screen (4 bytes, indexed by SCR_*)
scr_col    equ $00FFE3A5           ; saved cursor col per screen (4 bytes)
repatch    equ $00FFE3C3           ; 1 = re-push F1's patch on the next SCB push (Q/X cmds, edits)
live_algo  equ $00FFE3C4           ; transient ALGO override from a Q command ($FF = none)
live_vol   equ $00FFE3C5           ; transient VOL override from an X command ($FF = none)
eff_algo   equ $00FFE3C6           ; ym_setup scratch: effective ALGO (override or stored)
eff_vol    equ $00FFE3C7           ; ym_setup scratch: effective VOL
live_fb    equ $00FFE3C8           ; transient FB override from a Q command ($FF = none)
eff_fb     equ $00FFE3C9           ; ym_setup scratch: effective FB
env_ntdone equ $00FFE3CA           ; 0 = canvas nametable still needs writing this upload
env_slot   equ $00FFE3CB           ; envelope rasteriser: operator slot 0..3 being drawn
env_upos   equ $00FFE3CC           ; (word) upload cursor: next canvas tile to push
env_prevy  equ $00FFE3CE           ; envelope rasteriser: last plotted y (connector)
env_pts    equ $00FFE3D0           ; envelope breakpoints: 5 x (word) , a (word) pairs
env_canvas equ $00FFC000           ; envelope bitmap (ENV_TILES tiles, MD 4bpp); 4 KB

; screen IDs (kept stable so every dispatch site is unchanged); the map order
; (left..right SONG CHAIN PHRASE INSTR) is expressed by scr_order/scr_pos tables.
SCR_PHRASE equ 0
SCR_CHAIN  equ 1
SCR_SONG   equ 2
SCR_INSTR  equ 3
SCR_FM     equ 4                    ; FM editor (below INSTR on the map)
SCR_MAXPOS equ 3                    ; rightmost horizontal map position
scb_count  equ $00FFE220           ; PSG byte count + buffer
scb_data   equ $00FFE221
ym_count   equ $00FFE260           ; YM write count + buffer (triples)
ym_data    equ $00FFE261

phrases    equ $00FFF000            ; phrases pool (PHRASE_SIZE each)
PHRASE_SIZE equ 64
chains     equ $00FFF400            ; chains pool (CHAIN_SIZE each)
CHAIN_SIZE equ 32                   ; 16 steps x (phrase#, transpose)
song       equ $00FFF600            ; song matrix: NSONGROWS x NCH chain#s ($FF empty)
NSONGROWS  equ 16
instrum    equ $00FFF700            ; instrument pool (INSTR_SIZE each)
INSTR_SIZE equ 48                   ; type + algo/fb/pan + 4 ops x 10 params
NINSTR     equ 32
i_type     equ 0                    ; instrument field: type (0 FM, 1 SQ, 2 NO, 3 KIT)
i_algo     equ 1                    ; FM algorithm 0-7
i_fb       equ 2                    ; FM feedback 0-7
i_pan      equ 3                    ; FM stereo pan: 0 off, 1 R, 2 L, 3 L+R
i_ams      equ 4                    ; LFO amplitude-mod sensitivity 0-3
i_fms      equ 5                    ; LFO freq-mod (vibrato) sensitivity 0-7
i_hld      equ 6                    ; gate time: note-off after HLD*2 ticks; $F = hold
i_vol      equ 7                    ; instrument volume 0-15 (attenuates carriers); $F = full
i_op       equ 8                    ; 4 ops x 10: MUL DT TL RS AR AM D1 D2 RR SL
FM_NPARM   equ 10
NITYPE     equ 4
NPHRASE_ED equ 7                    ; highest editable phrase (C+Up/Down)
NCHAIN_ED  equ 7                    ; highest editable chain
NINSTR_ED  equ 31                   ; highest editable instrument

I_VOL      equ $F
I_HLD      equ $FF
I_DCY      equ 2
GROOVE     equ 10
GRID_TOP   equ 6

    org $000000

; ---- vectors ----
    dc.l $00FFFE00
    dc.l Start
    dcb.l 22, Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l VBlankInt
    dc.l Exception
    dcb.l 32, Exception

; ---- header ----
    dc.b "SEGA MEGA DRIVE "
    dcb.b $110-*, ' '
    dc.b "(C)GENMDDJ 2026 "
    dcb.b $120-*, ' '
    dc.b "GENMDDJ - MEGA DRIVE TRACKER"
    dcb.b $150-*, ' '
    dc.b "GENMDDJ - MEGA DRIVE TRACKER"
    dcb.b $180-*, ' '
    dc.b "GM GENMDDJ-00"
    dcb.b $18E-*, ' '
    dc.w $0000
    dc.b "J"
    dcb.b $1A0-*, ' '
    dc.l $00000000
    dc.l ROM_END-1
    dc.l $00FF0000
    dc.l $00FFFFFF
    dcb.b $1F0-*, ' '
    dc.b "JUE"
    dcb.b $200-*, ' '

; ============================================================
Start:
    move    #$2700, sr
    move.b  VERSION, d0
    andi.b  #$0F, d0
    beq.s   .nt
    move.l  #'SEGA', TMSS_REG
.nt:
    lea     VDP_CTRL, a0

    lea     vdp_regs, a1
    move.w  #$8000, d0
    moveq   #vdp_regs_end-vdp_regs-1, d1
.reg:
    move.b  (a1)+, d0
    move.w  d0, (a0)
    add.w   #$0100, d0
    dbra    d1, .reg

    move.l  #$40000000, (a0)            ; clear VRAM
    move.w  #($10000/2)-1, d0
.vc:
    move.w  #0, VDP_DATA
    dbra    d0, .vc

    move.l  #$44000000, (a0)            ; normal font -> VRAM $0400
    lea     font_data, a1
    move.w  #(3072/2)-1, d0
.fc:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fc
    move.l  #$50000000, (a0)            ; inverse font -> VRAM $1000
    move.w  #(3072/2)-1, d0
.fc2:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fc2
    move.l  #$43E00000, (a0)            ; playhead triangle -> tile $1F
    lea     tri_tile, a1
    moveq   #16-1, d0
.ft:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .ft
    move.l  #$60000000, (a0)            ; splash logo tiles -> VRAM $2000 (tile $100)
    lea     splash_tiles, a1
    move.w  #(SPLASH_NTILES*16)-1, d0
.fs:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fs
    move.l  #$6C000000, (a0)            ; FM algorithm tiles -> VRAM $2C00 (tile $160)
    lea     algo_tiles, a1
    move.w  #(ALGO_NTILES*16)-1, d0
.fa:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fa

    move.l  #$C0000000, (a0)            ; palette 0
    move.w  #$0E40, VDP_DATA            ; c0 sky blue (backdrop)
    move.w  #$00EE, VDP_DATA            ; c1 star yellow (text/cursor block)
    move.w  #$0E40, VDP_DATA            ; c2 sky blue (cursor glyph)

    move.b  #$40, IO_CTRL1

    bsr     z80_load

    ; clear phrase pool to rests ($FF,0,0,0 per row), 16 phrases
    lea     phrases, a2
    move.w  #16*16-1, d0
.clr:
    move.b  #$FF, (a2)+
    move.b  #0, (a2)+
    move.b  #0, (a2)+
    move.b  #0, (a2)+
    dbra    d0, .clr
    ; copy demo phrases over 0-3
    lea     demo_phrases, a1
    lea     phrases, a2
    move.w  #(demo_end-demo_phrases)-1, d0
.cp:
    move.b  (a1)+, (a2)+
    dbra    d0, .cp
    ; copy demo chains
    lea     demo_chains, a1
    lea     chains, a2
    move.w  #(demo_chains_end-demo_chains)-1, d0
.cc:
    move.b  (a1)+, (a2)+
    dbra    d0, .cc
    ; copy demo song
    lea     demo_song, a1
    lea     song, a2
    move.w  #(demo_song_end-demo_song)-1, d0
.cs:
    move.b  (a1)+, (a2)+
    dbra    d0, .cs
    ; clear instrument pool (all type 0 = FM)
    lea     instrum, a2
    move.w  #(NINSTR*INSTR_SIZE)-1, d0
.ci:
    move.b  #0, (a2)+
    dbra    d0, .ci
    lea     instrum, a2                   ; all instruments start as the default FM patch
    moveq   #NINSTR-1, d2
.cdfn:
    lea     default_fm, a1
    moveq   #INSTR_SIZE-1, d0
.cdf:
    move.b  (a1)+, (a2)+
    dbra    d0, .cdf
    dbra    d2, .cdfn

    bsr     engine_init
    bsr     ym_setup                     ; build YM ch0's patch from instrument 0
    move.b  #0, cur_row
    move.b  #0, cur_col
    move.b  #0, key_prev
    move.b  #0, key_rpt
    move.b  #0, dpad_prev
    move.b  #48, last_note
    move.b  #0, last_cmd
    move.b  #$FF, e_audnote
    move.b  #0, cur_phrase
    move.b  #0, playing                  ; boot stopped
    move.b  #SCR_SONG, cur_screen
    move.b  #0, cur_chain
    move.b  #0, cur_instr
    move.b  #0, cur_chan
    move.b  #0, cur_songrow
    lea     scr_row, a0                   ; per-screen saved cursors -> 0
    moveq   #7, d0
.clrscur:
    clr.b   (a0)+
    dbra    d0, .clrscur
    move.w  #0, g_ticks
    move.b  #0, play_mode
    move.b  #0, play_from
    move.b  #0, g_lfo                     ; FM LFO off by default
    move.b  #$FF, live_algo               ; no transient Q/X command overrides yet
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    move.b  #0, repatch
    move.b  #0, playing                  ; boot stopped
    move.b  #1, need_clear               ; draw header/name on first frame

    lea     VDP_CTRL, a0                  ; splash parked (H40 corruption to revisit)
    moveq   #1, d3
    moveq   #1, d4
    lea     str_title, a1
    bsr     print_at
    move    #$2000, sr
.forever:                                  ; idle loop does the heavy envelope raster
    tst.b   env_dirty                     ; (kept OUT of VBlank -- see env_rasterize)
    beq.s   .forever
    move.b  #0, env_dirty
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .forever
    bsr     env_rasterize
    clr.w   env_upos                      ; (re)start the chunked upload from tile 0
    clr.b   env_ntdone                    ; nametable first, then tile chunks
    move.b  #1, env_ready                 ; VBlank pushes it a chunk at a time
    bra.s   .forever

; ============================================================
VBlankInt:
    movem.l d0-d7/a0-a6, -(sp)
    tst.w   VDP_CTRL
    tst.b   in_splash                     ; power-up splash holds the screen
    beq.s   .run
    lea     VDP_CTRL, a0
    bsr     splash_tick
    bra     .vbend
.run:
    bsr     input_tick
    bsr     engine_tick
    lea     VDP_CTRL, a0
    ; redraw the grid only on change (per-frame VRAM writes during active H40
    ; display corrupt the picture); d7 = render-needed
    moveq   #0, d7
    tst.b   vdirty
    beq.s   .nv
    move.b  #0, vdirty
    moveq   #1, d7
.nv:
    tst.b   eng_adv
    beq.s   .nev
    move.b  #0, eng_adv
    moveq   #1, d7
.nev:
    tst.b   need_clear
    beq.s   .nc
    bsr     clear_grid
    moveq   #3, d3                        ; header at row3 col1
    moveq   #1, d4
    bsr     screen_ptr                     ; a1 = hdr table entry
    move.l  (a1), a1
    bsr     print_at
    moveq   #1, d3                        ; screen name at row1 col12
    moveq   #12, d4
    bsr     screen_ptr
    move.l  4(a1), a1
    bsr     print_at
    move.b  #0, need_clear
    move.b  #1, vdirty                    ; re-render next frame (header self-heals)
    move.b  #1, env_dirty
    moveq   #1, d7
.nc:
    bsr     get_playrow                   ; playhead position for this screen
    move.b  d0, play_row
    tst.b   d7
    beq     .gd                           ; unchanged -> skip the grid redraw
    move.b  cur_screen, d0                ; render active grid
    beq.s   .gph
    cmpi.b  #SCR_CHAIN, d0
    beq.s   .gch
    cmpi.b  #SCR_SONG, d0
    beq.s   .gsg
    bsr     render_fm                     ; INSTR (and FM) = the FM editor
    bra.s   .gd
.gch:
    bsr     render_chain
    bra.s   .gd
.gsg:
    bsr     render_song
    bra.s   .gd
.gph:
    bsr     render_phrase
.gd:
    addq.w  #1, g_ticks                  ; tick counter (4 hex) at row1 col35
    move.l  #$40C60003, (a0)
    move.w  g_ticks, d2
    lea     hexd, a1
    moveq   #3, d3
.tk:
    rol.w   #4, d2                        ; next nibble, MSB first
    move.w  d2, d0
    andi.w  #$000F, d0
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    dbra    d3, .tk
    move.l  #$40A60003, (a0)             ; screen number at row1 col19
    move.w  #'0', VDP_DATA
    moveq   #0, d0
    move.b  cur_screen, d1
    beq.s   .pnph
    cmpi.b  #SCR_CHAIN, d1
    beq.s   .pnch
    cmpi.b  #SCR_INSTR, d1
    beq.s   .pninst
    cmpi.b  #SCR_FM, d1
    bne.s   .pn                           ; SONG -> 0
.pninst:
    move.b  cur_instr, d0                 ; INSTR/FM -> instrument number
    bra.s   .pn
.pnch:
    move.b  cur_chain, d0
    bra.s   .pn
.pnph:
    move.b  cur_phrase, d0
.pn:
    lea     hexd, a1
    andi.w  #$000F, d0
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    move.b  cur_screen, d0                ; current track name at row1 col22
    beq.s   .tnshow                        ; PHRASE
    cmpi.b  #SCR_CHAIN, d0
    beq.s   .tnshow                        ; CHAIN
    move.l  #$40920003, (a0)              ; other screens: blank it
    move.w  #' ', VDP_DATA
    move.w  #' ', VDP_DATA
    bra.s   .tndone
.tnshow:
    move.l  #$40920003, (a0)             ; row1 col22
    moveq   #0, d0
    move.b  cur_chan, d0
    add.w   d0, d0
    lea     track_names, a1
    move.b  (a1,d0.w), d1
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    move.b  (1,a1,d0.w), d1
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
.tndone:
    lea     str_stop, a1                 ; transport at row3 col36
    tst.b   playing
    beq.s   .ps
    lea     str_play, a1
.ps:
    moveq   #3, d3
    moveq   #35, d4
    bsr     print_at
    bsr     draw_map                      ; map at row5 col35
    tst.b   env_ready                     ; push an envelope chunk every frame (budget OK)
    beq.s   .vbend
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .vbend
    move.b  #0, env_ready
    bsr     env_upload
.vbend:
    movem.l (sp)+, d0-d7/a0-a6
    rte

; ---- power-up splash ----
SPLASH_TILEBASE equ $0100                 ; VRAM $2000 / $20
SPLASH_COL  equ (40-SPLASH_W)/2
SPLASH_ROW  equ 8

splash_tick:                              ; a0 = VDP_CTRL; incremental draw + countdown
    move.b  splash_row, d5                ; one logo row per frame (fits the VBlank, so no
    cmpi.b  #SPLASH_H, d5                  ; display blanking is needed)
    bhs.s   .text
    ext.w   d5
    bsr     draw_splash_row
    addq.b  #1, splash_row
    bra.s   .cd
.text:
    bne.s   .cd                           ; past the text frame -> nothing to draw
    bsr     draw_splash_text
    addq.b  #1, splash_row
.cd:
    bsr     pad_read
    btst    #7, d0                        ; Start -> skip the splash
    bne.s   .end
    subq.w  #1, splash_ctr
    bne.s   .ret
.end:
    moveq   #8, d2                        ; clear only the logo's right edge (rows 8-13,
.ce:                                       ; cols 34-39); clear_grid wipes cols 0-33 and
    move.w  d2, d0                          ; the SONG render redraws the rest -- avoids
    lsl.w   #6, d0                          ; clear_splash's full-plane write burst
    addi.w  #34, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    addq.w  #1, d2
    cmpi.w  #14, d2
    bne.s   .ce
    moveq   #1, d3                        ; restore GENMDDJ title at row1 col1
    moveq   #1, d4
    lea     str_title, a1
    bsr     print_at
    move.w  #0, g_ticks                   ; tick count starts when the UI loads
    move.b  #0, in_splash
    move.b  #1, need_clear                ; redraw the UI next frame
.ret:
    rts

draw_splash_row:                          ; a0 = VDP_CTRL; d5 = logo tile row to draw
    moveq   #0, d0                        ; clear high word (swap below needs it 0)
    move.w  d5, d0
    addi.w  #SPLASH_ROW, d0
    lsl.w   #6, d0                        ; * 64
    addi.w  #SPLASH_COL, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     splash_map, a2                ; a2 = splash_map + row*SPLASH_W
    move.w  d5, d1
    mulu.w  #SPLASH_W, d1
    adda.w  d1, a2
    moveq   #SPLASH_W-1, d6
.sc:
    moveq   #0, d1
    move.b  (a2)+, d1                     ; local tile index
    addi.w  #SPLASH_TILEBASE, d1
    move.w  d1, VDP_DATA
    dbra    d6, .sc
    rts

draw_splash_text:                         ; a0 = VDP_CTRL; version + git stamp
    moveq   #SPLASH_ROW+SPLASH_H+1, d3
    moveq   #17, d4
    lea     ver_str, a1
    bsr     print_at
    moveq   #SPLASH_ROW+SPLASH_H+2, d3
    moveq   #16, d4
    lea     git_hash_str, a1
    bsr     print_at
    rts

clear_splash:                             ; a0 = VDP_CTRL; blank the visible plane
    moveq   #0, d2
.r:
    move.w  d2, d0
    lsl.w   #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #40-1, d3
.c:
    move.w  #0, VDP_DATA
    dbra    d3, .c
    addq.w   #1, d2
    cmpi.w  #28, d2
    bne.s   .r
    rts

; screen map widget: the screens in map order with the current one highlighted
draw_map:                                 ; a0 = VDP_CTRL
    move.l  #$43460003, (a0)             ; "SCPI" at row 6, col 35
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d1                 ; current map position
    lea     map_letters, a2
    moveq   #0, d2
.ml:
    moveq   #0, d0
    move.b  (a2,d2.w), d0                 ; letter at this position
    cmp.b   d1, d2
    bne.s   .nh
    addi.w  #$60, d0                       ; highlight current (inverse tile)
.nh:
    move.w  d0, VDP_DATA
    addq.w  #1, d2
    cmpi.w  #4, d2
    bne.s   .ml
    rts

; a1 -> {header_str, name_str} pair for the current screen
screen_ptr:
    lea     scr_ph_tab, a1
    move.b  cur_screen, d0
    beq.s   .r
    lea     scr_ch_tab, a1
    cmpi.b  #SCR_CHAIN, d0
    beq.s   .r
    lea     scr_sg_tab, a1
    cmpi.b  #SCR_SONG, d0
    beq.s   .r
    lea     scr_in_tab, a1
    cmpi.b  #SCR_INSTR, d0
    beq.s   .r
    lea     scr_fm_tab, a1
.r:
    rts

; ============================================================
; input
; ============================================================
input_tick:
    bsr     pad_read
    move.b  d0, d3
    move.b  key_prev, d4
    move.b  d3, key_prev
    not.b   d4
    and.b   d3, d4                       ; button edges
    btst    #7, d4                        ; Start -> toggle transport
    beq.s   .nstart
    bsr     toggle_play
.nstart:
    bsr     dpad_fire                     ; d5 = d-pad bits to act (once)
    move.b  d1, d5
    move.b  d4, d0                        ; any edge or d-pad action -> redraw grid
    or.b    d5, d0
    beq.s   .ndirty
    move.b  #1, vdirty
.ndirty:
    btst    #5, d4                        ; B tap (edge)
    beq.s   .ni
    btst    #6, d3                        ; C held + B tap -> context playback
    beq.s   .doins
    bsr     play_context
    rts
.doins:
    bsr     do_insert                     ; B tap alone -> insert/audition
.ni:
    btst    #5, d3                        ; B held -> edit modifier
    bne.s   .bheld
    btst    #6, d3                        ; else C held -> project modifier
    bne.s   .cheld
    btst    #4, d3                        ; else A held -> channel switch
    bne     .aheld
    tst.b   d5                            ; neither: d-pad moves cursor
    beq     .done
    move.b  d5, d2
    bsr     move_cursor
    rts
.bheld:
    btst    #6, d4                        ; B + C tap -> cut (clear cell)
    beq.s   .nbc
    bsr     do_cut
.nbc:
    tst.b   d5                            ; B + d-pad -> edit value
    beq     .done
    move.b  d5, d2
    bsr     edit_value
    cmpi.b  #SCR_FM, cur_screen           ; INSTR/FM edit -> re-apply patch (heard next note)
    beq.s   .reapply
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .ne
.reapply:
    bsr     ym_setup
    cmpi.b  #NVOICE+2, cur_row            ; only an operator edit changes an envelope
    blo.s   .ne
    move.b  #1, env_dirty
.ne:
    rts
.cheld:                                   ; C = map navigation + (temp) selector
    btst    #2, d5                         ; C+Left -> left on the map (toward SONG)
    beq.s   .nsl
    bsr     screen_left
.nsl:
    btst    #3, d5                         ; C+Right -> right on the map (drill in)
    beq.s   .nsr
    bsr     screen_right
.nsr:
    bsr     clamp_col
.done:
    rts

.aheld:                                   ; A + Left/Right -> switch channel (CHAIN/PHRASE only;
    move.b  cur_screen, d0                 ;   INSTR uses the INST field to pick the instrument)
    cmpi.b  #SCR_CHAIN, d0
    beq.s   .ado
    cmpi.b  #SCR_PHRASE, d0
    beq.s   .ado
    rts
.ado:
    btst    #2, d5                         ; A+Left -> previous channel
    beq.s   .arl
    move.b  cur_chan, d0
    beq.s   .arl
    subq.b  #1, d0
    move.b  d0, cur_chan
    bsr     load_chan
.arl:
    btst    #3, d5                         ; A+Right -> next channel
    beq.s   .adone
    move.b  cur_chan, d0
    cmpi.b  #NCH-1, d0
    beq.s   .adone
    addq.b  #1, d0
    move.b  d0, cur_chan
    bsr     load_chan
.adone:
    rts

; cur_chain/cur_phrase <- the chain/phrase channel cur_chan plays at cur_songrow
load_chan:
    lea     song, a1
    moveq   #0, d0
    move.b  cur_songrow, d0
    mulu.w  #NCH, d0                        ; songrow * NCH
    moveq   #0, d1
    move.b  cur_chan, d1
    add.w   d1, d0
    move.b  (a1,d0.w), d0                  ; chain# at song[songrow][chan]
    move.b  #1, need_clear
    cmpi.b  #$FF, d0
    beq.s   .lc_done                       ; empty cell -> keep current chain
    move.b  d0, cur_chain
    lea     chains, a1                     ; cur_phrase <- chain step 0 phrase#
    moveq   #0, d1
    move.b  cur_chain, d1
    lsl.w   #5, d1
    adda.w  d1, a1
    move.b  (a1), d1
    cmpi.b  #$FF, d1
    beq.s   .lc_done
    move.b  d1, cur_phrase
.lc_done:
    rts

; --- screen map navigation (positions: 0 SONG, 1 CHAIN, 2 PHRASE, 3 INSTR) ---
screen_left:
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d0                  ; current map position
    beq.s   .l_done                        ; already leftmost
    subq.b  #1, d0
    lea     scr_order, a1
    move.b  (a1,d0.w), cur_screen
    move.b  #1, need_clear
    moveq   #0, d1                          ; restore the parent screen's cursor (where we
    move.b  cur_screen, d1                  ;   drilled down from) instead of jumping to 0,0
    lea     scr_row, a1
    move.b  (a1,d1.w), cur_row
    lea     scr_col, a1
    move.b  (a1,d1.w), cur_col
.l_done:
    rts

screen_right:
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d0
    cmpi.b  #SCR_MAXPOS, d0
    bhs.s   .r_done                        ; already rightmost
    bsr     drill_down                     ; load the item under the cursor
    moveq   #0, d1                          ; remember this screen's cursor so screen_left
    move.b  cur_screen, d1                  ;   can bring us back to exactly this cell
    lea     scr_row, a1
    move.b  cur_row, (a1,d1.w)
    lea     scr_col, a1
    move.b  cur_col, (a1,d1.w)
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d0
    addq.b  #1, d0
    lea     scr_order, a1
    move.b  (a1,d0.w), cur_screen
    move.b  #1, need_clear
    move.b  #0, cur_row                    ; descending resets cursor to top
    move.b  #0, cur_col
.r_done:
    rts

drill_down:                               ; set the next screen's target from the cursor cell
    move.b  cur_screen, d0
    cmpi.b  #SCR_SONG, d0
    bne.s   .d1
    move.b  cur_col, cur_chan              ; SONG: establish the editing context
    move.b  cur_row, cur_songrow
    bsr     get_field_addr                 ; SONG cell -> chain
    move.b  (a1), d1
    cmpi.b  #$FF, d1
    beq.s   .d_done
    move.b  d1, cur_chain
    rts
.d1:
    cmpi.b  #SCR_CHAIN, d0
    bne.s   .d2
    lea     chains, a1                     ; CHAIN step PH -> phrase
    moveq   #0, d1
    move.b  cur_chain, d1
    lsl.w   #5, d1
    adda.w  d1, a1
    moveq   #0, d1
    move.b  cur_row, d1
    add.w   d1, d1
    move.b  (a1,d1.w), d1
    cmpi.b  #$FF, d1
    beq.s   .d_done
    move.b  d1, cur_phrase
    rts
.d2:
    cmpi.b  #SCR_PHRASE, d0
    bne.s   .d_done
    bsr     cur_phrase_addr                ; PHRASE row's instrument (offset 1)
    moveq   #0, d1
    move.b  cur_row, d1
    lsl.w   #2, d1
    addq.w  #1, d1
    move.b  (a1,d1.w), cur_instr
.d_done:
    rts

dpad_fire:
    move.b  d3, d0
    andi.b  #$0F, d0
    move.b  dpad_prev, d1
    move.b  d0, dpad_prev
    not.b   d1
    and.b   d0, d1
    beq.s   .held
    move.b  #16, key_rpt
    rts
.held:
    tst.b   d0
    beq.s   .none
    subq.b  #1, key_rpt
    bne.s   .none
    move.b  #4, key_rpt
    move.b  d0, d1
    rts
.none:
    moveq   #0, d1
    rts

move_cursor:
    btst    #0, d2
    beq.s   .nu
    move.b  cur_row, d0
    subq.b  #1, d0
    andi.b  #$0F, d0
    move.b  d0, cur_row
.nu:
    btst    #1, d2
    beq.s   .nd
    move.b  cur_row, d0
    addq.b  #1, d0
    andi.b  #$0F, d0
    move.b  d0, cur_row
.nd:
    btst    #2, d2
    beq.s   .nl
    move.b  cur_col, d0
    beq.s   .nl
    subq.b  #1, d0
    move.b  d0, cur_col
.nl:
    btst    #3, d2
    beq.s   .nr
    bsr     col_max                       ; d1 = max col for this screen
    move.b  cur_col, d0
    cmp.b   d1, d0
    bge.s   .nr
    addq.b  #1, d0
    move.b  d0, cur_col
.nr:
    bsr     clamp_row
    rts

clamp_row:                                ; INSTR/FM = 11 rows (TYPE, 6 voice, 4 ops)
    move.b  cur_screen, d0
    cmpi.b  #SCR_FM, d0
    beq.s   .fm
    cmpi.b  #SCR_INSTR, d0
    beq.s   .fm
    rts
.fm:
    move.b  cur_row, d0
    cmpi.b  #NVOICE+6, d0
    blo.s   .cr_done                      ; 0..NVOICE+5 ok; clamp to bottom op row
    move.b  #NVOICE+5, cur_row
.cr_done:
    rts

col_max:                                  ; -> d1 = highest column index for cur_screen
    move.b  cur_screen, d1
    beq.s   .ph
    cmpi.b  #SCR_SONG, d1
    beq.s   .sg
    cmpi.b  #SCR_INSTR, d1
    beq.s   .fm
    cmpi.b  #SCR_FM, d1
    beq.s   .fm
    moveq   #1, d1                        ; CHAIN: PH,TR
    rts
.fm:
    cmpi.b  #NVOICE+2, cur_row            ; TYPE/voice/LFO rows have one value; ops have 10
    bhs.s   .fmop
    moveq   #0, d1
    rts
.fmop:
    moveq   #FM_NPARM-1, d1
    rts
.ph:
    moveq   #3, d1                        ; PHRASE: NOT,IN,C,PR
    rts
.sg:
    moveq   #NCH-1, d1                    ; SONG: F1-F6 T1-T3 NO (10 tracks)
    rts
.in:
    moveq   #0, d1                        ; INSTR: single value column
    rts

clamp_col:                                ; clamp cur_col into the current screen
    bsr     col_max
    move.b  cur_col, d0
    cmp.b   d1, d0
    bls.s   .ok
    move.b  d1, cur_col
.ok:
    rts

; a1 = address of the current (cur_phrase) phrase
cur_phrase_addr:
    lea     phrases, a1
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0                         ; * PHRASE_SIZE (64)
    adda.w  d0, a1
    rts

do_cut:                                   ; clear field under cursor
    bsr     get_field_addr
    move.b  cur_screen, d0
    cmpi.b  #SCR_INSTR, d0                  ; INSTR field -> 0
    beq.s   .hex
    cmpi.b  #SCR_SONG, d0                   ; SONG: any cell -> $FF (empty)
    beq.s   .ff
    move.b  cur_col, d0
    bne.s   .hex
.ff:
    move.b  #$FF, (a1)                     ; note / phrase# / chain# -> empty
    rts
.hex:
    move.b  #0, (a1)                       ; instr/cmd/param/transpose/type -> 0
    rts

get_field_addr:                           ; -> a1 = cursor field byte
    move.b  cur_screen, d0
    beq.s   .phrase
    cmpi.b  #SCR_SONG, d0
    beq.s   .song
    cmpi.b  #SCR_INSTR, d0
    beq.s   .instr
    lea     chains, a1                     ; CHAIN: chains[cur_chain] + row*2 + col
    moveq   #0, d0
    move.b  cur_chain, d0
    lsl.w   #5, d0
    adda.w  d0, a1
    moveq   #0, d0
    move.b  cur_row, d0
    add.w   d0, d0
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.song:                                    ; song + row*NCH + col
    lea     song, a1
    moveq   #0, d0
    move.b  cur_row, d0
    mulu.w  #NCH, d0                        ; row * NCH
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.phrase:
    bsr     cur_phrase_addr
    moveq   #0, d0
    move.b  cur_row, d0
    lsl.w   #2, d0
    moveq   #0, d1
    move.b  cur_col, d1
    lea     field_boff, a2
    move.b  (a2,d1.w), d1
    andi.w  #$00FF, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.instr:                                   ; instrum[cur_instr] + field(cur_row)
    lea     instrum, a1
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a1
    moveq   #0, d0
    move.b  cur_row, d0
    adda.w  d0, a1
    rts

; FM cell edit: d2 = dpad bits; L/R = +-1, U/D = +-16, clamped to [0, param max]
edit_fm:
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    tst.b   cur_row
    beq     .instedit                      ; row 0 = INST selector
    cmpi.b  #1, cur_row
    beq.s   .typeedit                      ; row 1 = instrument TYPE
    cmpi.b  #NVOICE+2, cur_row
    bhs.s   .opedit
    moveq   #0, d0                         ; voice param (rows 2..NVOICE+1)
    move.b  cur_row, d0
    subq.b  #2, d0
    lea     voice_off, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1
    lea     0(a3,d1.w), a1
    lea     voice_max, a2
    moveq   #0, d3
    move.b  (a2,d0.w), d3
    bra.s   .adj
.typeedit:
    lea     (i_type,a3), a1
    moveq   #NITYPE-1, d3
    bra.s   .adj
.instedit:                                ; row 0: select which instrument to edit
    move.b  cur_instr, d0
    btst    #2, d2                          ; Left -> previous
    beq.s   .ie_r
    tst.b   d0
    beq.s   .ie_r
    subq.b  #1, d0
.ie_r:
    btst    #3, d2                          ; Right -> next
    beq.s   .ie_w
    cmpi.b  #NINSTR_ED, d0
    bhs.s   .ie_w
    addq.b  #1, d0
.ie_w:
    move.b  d0, cur_instr
    move.b  #1, need_clear                  ; re-render the whole instrument page
    move.b  #1, env_dirty                   ; new instrument -> re-rasterise envelopes
    rts
.opedit:
    moveq   #0, d0                         ; op grid: i_op + (row-(NVOICE+2))*10 + col
    move.b  cur_row, d0
    subi.w  #NVOICE+2, d0
    mulu.w  #FM_NPARM, d0
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    addi.w  #i_op, d0
    lea     0(a3,d0.w), a1
    lea     fm_pmax, a2
    moveq   #0, d3
    move.b  (a2,d1.w), d3
.adj:
    moveq   #0, d0
    move.b  (a1), d0
    btst    #2, d2
    beq.s   .e1
    subq.w  #1, d0
.e1:
    btst    #3, d2
    beq.s   .e2
    addq.w  #1, d0
.e2:
    btst    #0, d2
    beq.s   .e3
    addi.w  #$10, d0
.e3:
    btst    #1, d2
    beq.s   .e4
    subi.w  #$10, d0
.e4:
    tst.w   d0
    bpl.s   .nlo
    moveq   #0, d0
.nlo:
    cmp.w   d3, d0
    bls.s   .nhi
    move.w  d3, d0
.nhi:
    move.b  d0, (a1)
.efm_done:
    rts

edit_value:
    cmpi.b  #SCR_FM, cur_screen           ; INSTR/FM editor: edit the cell
    beq     edit_fm
    cmpi.b  #SCR_INSTR, cur_screen
    beq     edit_fm
    tst.b   cur_screen                    ; CHAIN/SONG: both cols are byte +-1/+-$10
    bne.s   .hexfield
    move.b  cur_col, d0
    beq.s   .note
    cmpi.b  #2, d0
    beq.s   .cmd
.hexfield:
    bsr     get_field_addr
    move.b  (a1), d0
    btst    #2, d2
    beq.s   .h1
    subq.b  #1, d0
.h1:
    btst    #3, d2
    beq.s   .h2
    addq.b  #1, d0
.h2:
    btst    #0, d2
    beq.s   .h3
    addi.b  #$10, d0
.h3:
    btst    #1, d2
    beq.s   .h4
    subi.b  #$10, d0
.h4:
    move.b  d0, (a1)
    rts
.cmd:
    bsr     get_field_addr
    move.b  (a1), d0
    btst    #3, d2
    beq.s   .cl
    addq.b  #1, d0
    cmpi.b  #27, d0
    blo.s   .cl
    moveq   #0, d0
.cl:
    btst    #2, d2
    beq.s   .cw
    tst.b   d0
    bne.s   .cdec
    moveq   #26, d0
    bra.s   .cw
.cdec:
    subq.b  #1, d0
.cw:
    move.b  d0, (a1)
    tst.b   d0                             ; remember the last real command for B-tap repeat
    beq.s   .cwr
    move.b  d0, last_cmd
.cwr:
    rts
.note:
    bsr     get_field_addr
    moveq   #0, d0
    move.b  (a1), d0
    cmpi.b  #$FF, d0
    bne.s   .nn
    moveq   #48, d0
.nn:
    btst    #2, d2
    beq.s   .n1
    subq.w  #1, d0
.n1:
    btst    #3, d2
    beq.s   .n2
    addq.w  #1, d0
.n2:
    btst    #0, d2
    beq.s   .n3
    addi.w  #12, d0
.n3:
    btst    #1, d2
    beq.s   .n4
    subi.w  #12, d0
.n4:
    bpl.s   .nlo
    moveq   #0, d0
.nlo:
    cmpi.w  #95, d0
    ble.s   .nhi
    move.w  #95, d0
.nhi:
    move.b  d0, (a1)
    move.b  d0, last_note
    move.b  d0, e_audnote
    bsr     prelisten
    rts

; INSTRUMENT: L/R cycles the field's value (type 0..NITYPE-1)
edit_instr:
    bsr     get_field_addr
    move.b  (a1), d0
    btst    #3, d2                         ; Right -> next
    beq.s   .ei1
    addq.b  #1, d0
    cmpi.b  #NITYPE, d0
    blo.s   .ei1
    moveq   #0, d0
.ei1:
    btst    #2, d2                         ; Left -> previous
    beq.s   .ei2
    tst.b   d0
    bne.s   .eidec
    moveq   #NITYPE-1, d0
    bra.s   .ei2
.eidec:
    subq.b  #1, d0
.ei2:
    move.b  d0, (a1)
    rts

do_insert:
    bsr     get_field_addr
    move.b  cur_col, d0
    beq.s   .ins_note                      ; col 0 = NOT -> insert/audition note
    cmpi.b  #2, d0                          ; col 2 = C (PHRASE command column)
    bne.s   .ret
    tst.b   cur_screen                      ; PHRASE only
    bne.s   .ret
    tst.b   (a1)                            ; only drop into an empty command cell
    bne.s   .ret
    move.b  last_cmd, (a1)                  ; B-tap repeats the last command entered
.ret:
    rts
.ins_note:
    move.b  (a1), d0
    cmpi.b  #$FF, d0
    bne.s   .audit
    move.b  last_note, d0
    move.b  d0, (a1)
.audit:
    move.b  d0, e_audnote
    bsr     prelisten
    rts

prelisten:                                ; audition e_audnote on channel 0
    moveq   #0, d0
    move.b  e_audnote, d0
    cmpi.b  #$FF, d0
    beq.s   .pd
    lea     ch_state, a6
    move.b  d0, c_note(a6)
    add.w   d0, d0
    lea     notetable, a1
    move.w  (a1,d0.w), c_period(a6)
    move.b  #1, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #0, c_vol(a6)
.pd:
    rts

; Read pad 1 -> d0.b = St C B A R L D U (active high). The first TH phase returns
; the standard buttons on BOTH 3- and 6-button pads (a 6-button pad starts each
; idle-reset read at phase 0), so this reads every button genmddj uses on either
; pad. The X/Y/Z/Mode extras (6-button only) are not read yet (no feature uses them;
; the extended-sequence read needs hardware verification - see Q3 / pad6_ex notes).
pad_read:
    move.b  #$40, IO_DATA1               ; TH=1
    nop
    nop
    move.b  IO_DATA1, d1                 ; U D L R B C
    move.b  #$00, IO_DATA1               ; TH=0
    nop
    nop
    move.b  IO_DATA1, d2                 ; . . . . A St
    move.b  #$40, IO_DATA1               ; leave TH high (idle resets a 6-button pad)
    not.b   d1
    not.b   d2
    moveq   #0, d0
    move.b  d1, d0
    andi.b  #$0F, d0                     ; U D L R
    btst    #4, d1                        ; B -> bit5
    beq.s   .b
    bset    #5, d0
.b:
    btst    #5, d1                        ; C -> bit6
    beq.s   .c
    bset    #6, d0
.c:
    btst    #4, d2                        ; A -> bit4
    beq.s   .a
    bset    #4, d0
.a:
    btst    #5, d2                        ; Start -> bit7
    beq.s   .s
    bset    #7, d0
.s:
    rts

; ============================================================
; render PHRASE grid (phrase 0)
; ============================================================
render_phrase:
    moveq   #0, d6
.rl:
    bsr     draw_rowhdr
    moveq   #0, d5
.cl:
    moveq   #0, d4
    move.b  cur_row, d0
    cmp.b   d6, d0
    bne.s   .np
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .np
    move.w  #$60, d4
.np:
    bsr     render_field
    addq.b  #1, d5
    cmpi.b  #4, d5
    bne.s   .cl
    addq.b  #1, d6
    cmpi.b  #16, d6
    bne.s   .rl
    rts

render_field:
    movem.l d5-d6/a1-a2, -(sp)
    lea     field_scol, a1
    move.b  (a1,d5.w), d7
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     field_boff, a1
    move.b  (a1,d5.w), d1
    andi.w  #$00FF, d1
    move.w  d6, d2
    lsl.w   #2, d2
    add.w   d1, d2
    lea     phrases, a2                   ; + cur_phrase * 64
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0
    adda.w  d0, a2
    move.b  (a2,d2.w), d3
    move.b  d5, d0
    beq.s   .note
    cmpi.b  #2, d0
    beq.s   .cmd
    bsr     draw_hex2
    bra.s   .done
.note:
    bsr     draw_note
    bra.s   .done
.cmd:
    bsr     draw_cmd
.done:
    movem.l (sp)+, d5-d6/a1-a2
    rts

; ============================================================
; render CHAIN grid: 16 steps x (phrase#, transpose) of cur_chain
; ============================================================
render_chain:
    moveq   #0, d6
.rl:
    bsr     draw_rowhdr
    moveq   #0, d5
.cl:
    moveq   #0, d4
    move.b  cur_row, d0
    cmp.b   d6, d0
    bne.s   .np
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .np
    move.w  #$60, d4
.np:
    bsr     render_cfield
    addq.b  #1, d5
    cmpi.b  #2, d5
    bne.s   .cl
    addq.b  #1, d6
    cmpi.b  #16, d6
    bne.s   .rl
    rts

render_cfield:                            ; d5=field(0=PH,1=TR), d6=row, d4=cursor off
    movem.l d4-d6/a1-a2, -(sp)
    lea     chain_scol, a1
    move.b  (a1,d5.w), d7
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     chains, a2                     ; chains[cur_chain] + row*2
    moveq   #0, d0
    move.b  cur_chain, d0
    lsl.w   #5, d0
    adda.w  d0, a2
    move.w  d6, d2
    add.w   d2, d2
    move.b  (a2,d2.w), d0                  ; step's phrase# (empty if $FF)
    cmpi.b  #$FF, d0
    beq.s   .empty                         ; empty step -> both fields "--"
    moveq   #0, d1
    move.b  d5, d1
    add.w   d1, d2
    move.b  (a2,d2.w), d3
    bsr     draw_hex2
    bra.s   .done
.empty:
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
.done:
    movem.l (sp)+, d4-d6/a1-a2
    rts

clear_grid:                               ; a0=VDP_CTRL; blank header + grid + envelope (3..24)
    moveq   #0, d2
.row:
    moveq   #0, d0
    move.w  d2, d0
    addi.w  #3, d0                         ; from row 3 (header)
    lsl.w   #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #34-1, d3                      ; cols 0-33 (covers the wide SONG header)
.col:
    move.w  #' ', VDP_DATA
    dbra    d3, .col
    addq.w   #1, d2
    cmpi.w  #24, d2                        ; rows 3..26 (canvas + OP labels)
    bne.s   .row
    rts

; draw a row's left edge: col1 = row# hex, col2 = space, col3 = playhead triangle
; (col3 sits directly left of the first data column at col4)
draw_rowhdr:                              ; d6 = row; a0 = VDP_CTRL
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addq.w  #1, d0                        ; col1
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d6, d0                        ; col1 row# hex
    lea     hexd, a1
    andi.w  #$000F, d0
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    move.w  #' ', VDP_DATA                ; col2 space
    move.w  #$20, d1                      ; col3 playhead (triangle or space)
    move.b  play_row, d0
    cmp.b   d6, d0
    bne.s   .nm
    move.w  #$1F, d1
.nm:
    move.w  d1, VDP_DATA
    rts

; compute the playhead row for the current screen -> d0 ($FF if not shown)
get_playrow:                              ; shared single playhead (PHRASE/CHAIN only)
    tst.b   playing
    beq.s   .none
    move.b  cur_screen, d1
    beq.s   .phrase
    cmpi.b  #SCR_CHAIN, d1
    bne.s   .none                         ; SONG uses per-track markers; others none
    bra.s   .chain
.phrase:                                  ; row of a channel playing cur_phrase
    moveq   #0, d2
    move.b  cur_phrase, d2
    lsl.w   #6, d2
    lea     phrases, a1
    adda.w  d2, a1
    lea     ch_state, a6
    moveq   #NCH-1, d2
.pl:
    movea.l c_phrase(a6), a2
    cmpa.l  a1, a2
    beq.s   .pf
    lea     CHSIZE(a6), a6
    dbra    d2, .pl
    bra.s   .none
.pf:
    move.b  c_row(a6), d0
    rts
.chain:                                   ; step of a channel playing cur_chain
    move.b  cur_chain, d3
    lea     ch_state, a6
    moveq   #NCH-1, d2
.cl:
    move.b  c_chain(a6), d0
    cmp.b   d3, d0
    beq.s   .cf
    lea     CHSIZE(a6), a6
    dbra    d2, .cl
    bra.s   .none
.cf:
    move.b  c_cstep(a6), d0
    rts
.none:
    moveq   #-1, d0                       ; $FF -> no row matches
    rts

; ============================================================
; render SONG grid: 16 rows x NCH track columns of chain#s
; ============================================================
render_song:
    moveq   #0, d6
.rl:
    bsr     draw_rowhdr
    moveq   #0, d5
.cl:
    moveq   #0, d4
    move.b  cur_row, d0
    cmp.b   d6, d0
    bne.s   .np
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .np
    move.w  #$60, d4
.np:
    bsr     render_sfield
    addq.b  #1, d5
    cmpi.b  #NCH, d5
    bne.s   .cl
    addq.b  #1, d6
    cmpi.b  #16, d6
    bne.s   .rl
    rts

render_sfield:                            ; d5=track col, d6=row, d4=cursor off
    movem.l d4-d6/a1-a2, -(sp)
    lea     song_scol, a1
    move.b  (a1,d5.w), d7
    subq.b  #1, d7                          ; marker column (one left of the chain#)
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #$20, d0                       ; per-track playhead marker (this column)
    tst.b   playing
    beq.s   .nomark
    move.w  d5, d1                          ; channel = ch_state + col*CHSIZE
    mulu.w  #CHSIZE, d1
    lea     ch_state, a2
    adda.w  d1, a2
    cmpi.b  #$FF, c_chain(a2)              ; inactive channel -> no marker
    beq.s   .nomark
    move.b  c_songpos(a2), d1
    cmp.b   d6, d1                          ; row == this channel's song position?
    bne.s   .nomark
    move.w  #$1F, d0                        ; triangle
.nomark:
    move.w  d0, VDP_DATA
    lea     song, a2                       ; chain# at song[row*NCH + col]
    move.w  d6, d2
    mulu.w  #NCH, d2
    moveq   #0, d1
    move.b  d5, d1
    add.w   d1, d2
    move.b  (a2,d2.w), d3
    cmpi.b  #$FF, d3                        ; empty cell -> "--"
    beq.s   .empty
    bsr     draw_hex2
    bra.s   .done
.empty:
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
.done:
    movem.l (sp)+, d4-d6/a1-a2
    rts

; ============================================================
; render INSTRUMENT screen: field list for cur_instr (TYPE for now)
; ============================================================
render_instr:
    moveq   #0, d0                        ; "TYPE" label at (GRID_TOP, col1)
    move.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addq.w  #1, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     str_type, a1
.ll:
    move.b  (a1)+, d1
    beq.s   .ld
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    bra.s   .ll
.ld:
    moveq   #0, d4                        ; cursor highlight on field 0
    tst.b   cur_row
    bne.s   .nc
    tst.b   cur_col
    bne.s   .nc
    move.w  #$60, d4
.nc:
    moveq   #0, d0                        ; type value at (GRID_TOP, col6)
    move.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addi.w  #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     instrum, a1
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    move.b  (a1,d0.w), d1                 ; type
    andi.w  #$0003, d1
    add.w   d1, d1
    lea     type_names, a1
    move.b  (a1,d1.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.b  (1,a1,d1.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

FM_VHDR equ 6                             ; VOICE: header (INST + TYPE above it)
FM_VTOP equ 7                             ; voice params, one per row, LFO at FM_VTOP+NVOICE
FM_OHDR equ 16                            ; operator grid header (INST + gaps, no LFO row)
FM_OTOP equ 17                            ; operator grid
ALGO_TILEBASE equ $0160                   ; algorithm tiles -> VRAM $2C00 / $20
ALGO_DIAG_ROW equ 6                       ; algorithm diagram (2x size)
ALGO_DIAG_COL equ 12
ENV_TW  equ 32                            ; envelope canvas: 4 ops x 8 tiles wide, 4 tall
ENV_TH  equ 4
ENV_TILES equ ENV_TW*ENV_TH
ENV_W   equ ENV_TW*8                      ; canvas px (256 x 32), each op = 64px sub-column
ENV_H   equ ENV_TH*8
ENV_VRAM equ $3400                        ; canvas tiles -> VRAM (after the algo tiles)
ENV_TILEBASE equ ENV_VRAM/$20
ENV_ROW equ 22                            ; canvas nametable position (below the op grid)
ENV_COL equ 2
ENV_LBLROW equ ENV_ROW+ENV_TH              ; OP labels centered below the boxes
ENV_CHUNK equ 16                          ; canvas tiles uploaded per frame (~256 words)
ENV_SUBW equ 64                           ; per-operator lane width (px)
ENV_BOXT equ 1                            ; box top edge (1px margin from lane edge)
ENV_BOXB equ ENV_H-2                       ; box bottom edge
ENV_TOP equ ENV_BOXT+1                     ; curve/guide top: 1px INSIDE the box
ENV_BOT equ ENV_BOXB-1                     ; curve/guide baseline: 1px inside the box
ENV_AMAX equ ENV_BOT-ENV_TOP               ; max amplitude in px (curve clears the borders)

; FM editor: VOICE section (one param per row) then the 4-operator grid
render_fm:                                ; a0 = VDP_CTRL
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3                         ; a3 = instrum[cur_instr]
    moveq   #3, d3                         ; INST selector (cur_row 0)
    moveq   #1, d4
    lea     str_inst, a1
    bsr     print_at
    move.l  #$41900003, (a0)              ; instrument number at row 3, col 8
    move.b  cur_instr, d3
    moveq   #0, d4
    tst.b   cur_row                        ; highlight when cur_row == 0
    bne.s   .inh
    moveq   #$60, d4
.inh:
    bsr     draw_hex2
    moveq   #4, d3                         ; TYPE field (cur_row 1)
    moveq   #1, d4
    lea     str_type, a1
    bsr     print_at
    move.l  #$42100003, (a0)              ; type name at row 4, col 8
    moveq   #0, d1
    move.b  (i_type,a3), d1
    andi.w  #$0003, d1
    add.w   d1, d1
    lea     type_names, a1
    moveq   #0, d4
    cmpi.b  #1, cur_row                    ; highlight when cur_row == 1
    bne.s   .tnh
    moveq   #$60, d4
.tnh:
    move.b  (a1,d1.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.b  (1,a1,d1.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    moveq   #FM_VHDR, d3                   ; "VOICE:" header
    moveq   #1, d4
    lea     str_voice, a1
    bsr     print_at
    moveq   #0, d6                         ; voice param 0..4 (ALGO FB PAN AMS FMS)
.vrow:
    move.w  d6, d3                          ; label at (FM_VTOP+idx, col1)
    addi.w  #FM_VTOP, d3
    cmpi.w  #3, d6                          ; blank row after PAN (groups ALGO/FB/PAN)
    blo.s   .vng1
    addq.w  #1, d3
.vng1:
    moveq   #1, d4
    move.w  d6, d0
    lsl.w   #2, d0
    lea     voice_lbl, a1
    move.l  (a1,d0.w), a1
    bsr     print_at
    moveq   #0, d0                          ; value at (FM_VTOP+idx, col8)
    move.w  d6, d0
    addi.w  #FM_VTOP, d0
    cmpi.w  #3, d6
    blo.s   .vng2
    addq.w  #1, d0
.vng2:
    lsl.w   #6, d0
    addi.w  #8, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     voice_off, a1
    moveq   #0, d0
    move.b  (a1,d6.w), d0
    move.b  (a3,d0.w), d3                  ; value
    moveq   #0, d4
    move.b  cur_row, d1                    ; highlight if cur_row-2 == voice idx
    subq.b  #2, d1
    cmp.b   d6, d1
    bne.s   .vnh
    moveq   #$60, d4
.vnh:
    bsr     draw_hex1
    addq.w  #1, d6
    cmpi.w  #NVOICE, d6
    bne.s   .vrow
    moveq   #FM_OHDR, d3                    ; operator grid header (LFO moved to PROJECT screen)
    moveq   #1, d4
    lea     str_hdr_fm, a1
    bsr     print_at
    moveq   #0, d6                          ; operator row 0..3
.oprow:
    moveq   #0, d0                          ; "OPn" at (FM_OTOP+op, col1)
    move.w  d6, d0
    addi.w  #FM_OTOP, d0
    lsl.w   #6, d0
    addq.w  #1, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d6, d0
    add.w   d6, d0
    add.w   d6, d0                         ; op * 3
    lea     op_names, a1
    adda.w  d0, a1
    moveq   #2, d2
.oplbl:
    move.b  (a1)+, d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    dbra    d2, .oplbl
    moveq   #0, d5                         ; param 0..7
.parm:
    moveq   #0, d0                         ; addr at (FM_OTOP+op, fm_scol[param])
    move.w  d6, d0
    addi.w  #FM_OTOP, d0
    lsl.w   #6, d0
    lea     fm_scol, a1
    moveq   #0, d1
    move.b  (a1,d5.w), d1
    add.w   d1, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d6, d0                         ; value = a3[i_op + op*10 + param]
    mulu.w  #FM_NPARM, d0
    add.w   d5, d0
    move.b  (i_op,a3,d0.w), d3
    moveq   #0, d4                          ; highlight if cur_row==NVOICE+2+op && cur_col==param
    move.b  cur_row, d1
    subi.b  #NVOICE+2, d1
    cmp.b   d6, d1
    bne.s   .nhl
    move.b  cur_col, d1
    cmp.b   d5, d1
    bne.s   .nhl
    moveq   #$60, d4
.nhl:
    lea     fm_pmax, a1                    ; max <= 15 -> show one nibble, else two
    move.b  (a1,d5.w), d1
    cmpi.b  #16, d1
    bhs.s   .wide
    bsr     draw_hex1
    bra.s   .pnext
.wide:
    bsr     draw_hex2
.pnext:
    addq.w  #1, d5
    cmpi.w  #FM_NPARM, d5
    bne     .parm
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .oprow
    bsr     draw_algo_diagram             ; a3 still = instrum[cur_instr]
    moveq   #0, d5                         ; OP labels centered under each envelope box
.eolbl:
    moveq   #0, d0                          ; clear high word (swap below puts it in cmd low!)
    move.w  d5, d0
    lsl.w   #3, d0                         ; slot*8
    addi.w  #ENV_LBLROW*64+ENV_COL+2, d0   ; row 25, col = ENV_COL+2 + slot*8 (centered)
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d5, d0                         ; op_names[slot*3 .. +2] = OP1/OP3/OP2/OP4
    add.w   d5, d0
    add.w   d5, d0
    lea     op_names, a1
    adda.w  d0, a1
    moveq   #2, d6
.eolc:
    move.b  (a1)+, d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    dbra    d6, .eolc
    addq.w  #1, d5
    cmpi.w  #4, d5
    bne.s   .eolbl
    rts

; draw the current algorithm's routing diagram (tilemap) for instrum a3
draw_algo_diagram:                        ; a0 = VDP_CTRL, a3 = instrument
    moveq   #0, d0
    move.b  (i_algo,a3), d0
    andi.w  #7, d0
    mulu.w  #ALGO_MAPSZ, d0
    lea     algo_maps, a2
    adda.w  d0, a2                         ; a2 = this algorithm's tilemap
    moveq   #0, d5                         ; tile row 0..ALGO_H-1
.ar:
    moveq   #0, d0                         ; addr at (ALGO_DIAG_ROW+row, ALGO_DIAG_COL)
    move.w  d5, d0
    addi.w  #ALGO_DIAG_ROW, d0
    lsl.w   #6, d0
    addi.w  #ALGO_DIAG_COL, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #ALGO_W-1, d6
.ac:
    moveq   #0, d1
    move.b  (a2)+, d1
    addi.w  #ALGO_TILEBASE, d1
    move.w  d1, VDP_DATA
    dbra    d6, .ac
    addq.w  #1, d5
    cmpi.w  #ALGO_H, d5
    bne.s   .ar
    rts

; ---- envelope diagram -----------------------------------------------------
; rasterise the current operator's ADSR shape into env_canvas, then DMA it.
; the envelope is y = f(x), so each column is one y -> no general line algo;
; consecutive columns are joined with a vertical run (env_colpix).
; env_rasterize: draw the curve into env_canvas (RAM only -- runs in the main
; loop, NOT in VBlank: it is far too heavy for the ~18k-cycle VBlank budget).
env_rasterize:
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3                         ; a3 = instrum[cur_instr]
    lea     env_canvas, a1                 ; clear the whole bitmap (all 4 envelopes)
    move.w  #(ENV_TILES*32/4)-1, d0
    moveq   #0, d1
.declr:
    move.l  d1, (a1)+
    dbra    d0, .declr
    move.b  #0, env_slot                  ; draw each operator into its 64px sub-column
.deslot:
    moveq   #0, d0                         ; a4 = this slot's op params
    move.b  env_slot, d0
    mulu.w  #FM_NPARM, d0
    addi.w  #i_op, d0
    lea     0(a3,d0.w), a4
    moveq   #0, d0                         ; aPeak = (127-TL) * ENV_AMAX / 127
    move.b  (2,a4), d0
    neg.w   d0
    addi.w  #127, d0
    mulu.w  #ENV_AMAX, d0
    divu.w  #127, d0
    andi.l  #$FFFF, d0
    move.w  d0, d3                         ; d3 = aPeak
    moveq   #0, d0                         ; aSus = aPeak * (15-SL) / 15
    move.b  (9,a4), d0
    andi.w  #$0F, d0
    neg.w   d0
    addi.w  #15, d0
    mulu.w  d3, d0
    divu.w  #15, d0
    andi.l  #$FFFF, d0
    move.w  d0, d4                         ; d4 = aSus
    moveq   #0, d0                         ; aSus2 = aSus * (31-D2) / 31
    move.b  (7,a4), d0
    andi.w  #$1F, d0
    neg.w   d0
    addi.w  #31, d0
    mulu.w  d4, d0
    divu.w  #31, d0
    andi.l  #$FFFF, d0
    move.w  d0, d5                         ; d5 = aSus2
    moveq   #0, d6                         ; x base = slot*64 + 2 (1px inside the box left)
    move.b  env_slot, d6
    lsl.w   #6, d6
    addq.w  #2, d6
    lea     env_pts, a2                    ; build (x,a) breakpoints (widths halved)
    move.w  d6, (a2)+                      ; P0 x = base
    clr.w   (a2)+                          ;    a = 0
    moveq   #0, d0                         ; wA = (31-AR)>>1
    move.b  (4,a4), d0
    andi.w  #$1F, d0
    moveq   #31, d1
    sub.w   d0, d1
    lsr.w   #1, d1
    add.w   d1, d6
    move.w  d6, (a2)+                      ; P1 x
    move.w  d3, (a2)+                      ;    a = aPeak
    moveq   #0, d0                         ; wD1 = (31-D1)>>1
    move.b  (6,a4), d0
    andi.w  #$1F, d0
    moveq   #31, d1
    sub.w   d0, d1
    lsr.w   #1, d1
    add.w   d1, d6
    move.w  d6, (a2)+                      ; P2 x
    move.w  d4, (a2)+                      ;    a = aSus
    addi.w  #12, d6                        ; sustain hold (halved)
    move.w  d6, (a2)+                      ; P3 x
    move.w  d5, (a2)+                      ;    a = aSus2
    moveq   #0, d0                         ; wR = (31-RR)>>1
    move.b  (8,a4), d0
    andi.w  #$1F, d0
    moveq   #31, d1
    sub.w   d0, d1
    lsr.w   #1, d1
    add.w   d1, d6
    move.w  d6, (a2)+                      ; P4 x
    clr.w   (a2)+                          ;    a = 0
    bsr     env_decor                      ; box + dashed timing/amplitude guides (behind)
    move.w  #ENV_BOT, env_prevy            ; connector starts at this envelope's baseline
    lea     env_pts, a2                    ; draw the 4 segments
.deseg:
    move.w  (a2), d0
    move.w  2(a2), d1
    move.w  4(a2), d2
    move.w  6(a2), d3
    bsr     env_seg
    addq.l  #4, a2
    cmpa.l  #env_pts+16, a2
    bne.s   .deseg
    addq.b  #1, env_slot
    cmpi.b  #4, env_slot
    blo     .deslot
    rts

; env_upload: push ENV_CHUNK canvas tiles to VRAM and advance env_upos. Runs
; one chunk per idle VBlank frame -- a full 64-tile blit overruns H40 VBlank and
; tears the picture, so the upload is spread over several frames. Keeps env_ready
; set until the whole canvas (and the static nametable, written on the first
; chunk) has been sent. a0 = VDP_CTRL on entry.
env_upload:
    tst.b   env_ntdone                     ; nametable gets its own frame (128 words)
    bne.s   .eutiles
    st      env_ntdone
    move.b  #1, env_ready                  ; tiles follow on subsequent idle frames
    moveq   #0, d5
.eunrow:
    moveq   #0, d0                          ; clear high word (swap below puts it in cmd low!)
    move.w  d5, d0
    addi.w  #ENV_ROW, d0
    lsl.w   #6, d0
    addi.w  #ENV_COL, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d5, d1
    mulu.w  #ENV_TW, d1
    addi.w  #ENV_TILEBASE, d1
    moveq   #ENV_TW-1, d2
.euncol:
    move.w  d1, VDP_DATA
    addq.w  #1, d1
    dbra    d2, .euncol
    addq.w  #1, d5
    cmpi.w  #ENV_TH, d5
    bne.s   .eunrow
    rts                                       ; nametable done -> tiles next frame
.eutiles:
    move.w  env_upos, d1                   ; VRAM addr = ENV_VRAM + env_upos*32
    lsl.w   #5, d1
    addi.w  #ENV_VRAM, d1                   ; addr spans $3400..$43FF (crosses $4000!)
    move.w  d1, d2                          ; A15,A14 -> command low word bits 1,0
    rol.w   #2, d2
    andi.w  #3, d2
    moveq   #0, d0
    move.w  d1, d0
    andi.w  #$3FFF, d0                      ; A13..A0 -> high word
    swap    d0
    or.w    d2, d0
    ori.l   #$40000000, d0
    move.l  d0, (a0)
    lea     env_canvas, a1                 ; source = env_canvas + env_upos*32
    move.w  env_upos, d1
    lsl.w   #5, d1
    adda.w  d1, a1
    move.w  #(ENV_CHUNK*16)-1, d0
.eutc:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .eutc
    addi.w  #ENV_CHUNK, env_upos           ; next chunk, or finish the burst
    cmpi.w  #ENV_TILES, env_upos
    blo.s   .eumore
    clr.w   env_upos
    rts
.eumore:
    move.b  #1, env_ready                  ; more chunks -> keep going next idle frame
    rts

; env_seg: draw segment (d0=x0,d1=a0) -> (d2=x1,d3=a1); joins from env_prevy.
; clobbers d0-d7,a1; preserves a0,a2,a3.
env_seg:
    move.w  d2, d4
    sub.w   d0, d4                         ; dx
    bne.s   .esm
    move.w  d0, d5                         ; dx=0: single column at x0
    move.w  #ENV_BOT, d6
    sub.w   d3, d6
    bra.s   env_colpix
.esm:
    move.w  d0, d5                         ; x = x0
.esl:
    move.w  d3, d6                         ; a = a0 + (a1-a0)*(x-x0)/dx
    sub.w   d1, d6
    move.w  d5, d7
    sub.w   d0, d7
    muls.w  d7, d6
    divs.w  d4, d6
    add.w   d1, d6
    bpl.s   .esp
    moveq   #0, d6
.esp:
    cmpi.w  #ENV_AMAX, d6
    bls.s   .esc
    move.w  #ENV_AMAX, d6
.esc:
    move.w  #ENV_BOT, d7
    sub.w   d6, d7
    move.w  d7, d6                         ; d6 = y
    bsr     env_colpix
    addq.w  #1, d5
    cmp.w   d2, d5
    ble.s   .esl
    rts

; env_colpix: at column d5=x, fill from env_prevy to d6=y; clobbers d6,d7; keeps d0-d5
env_colpix:
    move.w  d6, d7                         ; d7 = target y
    move.w  env_prevy, d6                  ; d6 = old prev = start of the run
    move.w  d7, env_prevy                  ; remember target for the next column
    cmp.w   d7, d6                         ; iterate d6 from prev toward target d7
    ble.s   .ecu
.ecd:
    bsr     env_setpix
    subq.w  #1, d6
    cmp.w   d7, d6
    bge.s   .ecd
    rts
.ecu:
    bsr     env_setpix
    addq.w  #1, d6
    cmp.w   d7, d6
    ble.s   .ecu
    rts

; env_setpix: set colour-1 pixel at (d5=x,d6=y) in env_canvas; preserves all but flags
env_setpix:
    movem.l d0-d2/a1, -(sp)
    move.w  d6, d0
    lsr.w   #3, d0
    mulu.w  #ENV_TW, d0                    ; tile_row * ENV_TW
    move.w  d5, d1
    lsr.w   #3, d1
    add.w   d1, d0                         ; + tile_col = tile index
    lsl.w   #5, d0                         ; * 32 bytes
    move.w  d6, d1
    andi.w  #7, d1
    lsl.w   #2, d1                         ; (y&7) * 4
    add.w   d1, d0
    move.w  d5, d1
    andi.w  #7, d1
    lsr.w   #1, d1                         ; (x&7) >> 1 = byte within the tile row
    add.w   d1, d0                         ; byte offset
    lea     env_canvas, a1
    move.b  #$10, d2                       ; even x -> high nibble
    btst    #0, d5
    beq.s   .spw
    move.b  #$01, d2                       ; odd x -> low nibble
.spw:
    or.b    d2, (a1,d0.w)
    movem.l (sp)+, d0-d2/a1
    rts

; env_hl: horizontal line/dash. d2=x0, d3=x1, d4=y, d7=0 solid / 1 dashed. keeps d2-d4,d7.
env_hl:
    move.w  d2, d5
.hll:
    tst.w   d7
    beq.s   .hlp
    btst    #0, d5                          ; dashed: only even columns
    bne.s   .hls
.hlp:
    move.w  d4, d6
    bsr     env_setpix
.hls:
    addq.w  #1, d5
    cmp.w   d3, d5
    ble.s   .hll
    rts

; env_vl: vertical line/dash. d4=x, d2=y0, d3=y1, d7=0 solid / 1 dashed. keeps d2-d4,d7.
env_vl:
    move.w  d2, d6
.vll:
    tst.w   d7
    beq.s   .vlp
    btst    #0, d6                          ; dashed: only even rows
    bne.s   .vls
.vlp:
    move.w  d4, d5
    bsr     env_setpix
.vls:
    addq.w  #1, d6
    cmp.w   d3, d6
    ble.s   .vll
    rts

; env_decor: bounding box (solid) + dashed timing/amplitude guides for env_slot.
; env_pts must hold the breakpoints; clobbers d0-d7,a1,a2.
env_decor:
    moveq   #0, d0                          ; box left = slot*64 + 1
    move.b  env_slot, d0
    lsl.w   #6, d0
    addq.w  #1, d0
    move.w  d0, d2                          ; box left
    move.w  d0, d3
    addi.w  #ENV_SUBW-3, d3                 ; box right (base+62)
    moveq   #ENV_BOXT, d4                   ; top edge
    moveq   #0, d7
    bsr     env_hl
    moveq   #ENV_BOXB, d4                   ; bottom edge
    moveq   #0, d7
    bsr     env_hl
    move.w  d2, d4                          ; left edge
    moveq   #ENV_BOXT, d2
    moveq   #ENV_BOXB, d3
    moveq   #0, d7
    bsr     env_vl
    moveq   #0, d0                          ; right edge
    move.b  env_slot, d0
    lsl.w   #6, d0
    addi.w  #ENV_SUBW-2, d0
    move.w  d0, d4
    moveq   #ENV_BOXT, d2
    moveq   #ENV_BOXB, d3
    moveq   #0, d7
    bsr     env_vl
    lea     env_pts, a2                    ; dashed vertical guides (1px inside the box)
    move.w  4(a2), d4                       ; P1.x (attack end)
    bsr     .vdash
    move.w  8(a2), d4                       ; P2.x (decay end)
    bsr     .vdash
    move.w  12(a2), d4                      ; P3.x (sustain end)
    bsr     .vdash
    moveq   #0, d0                          ; dashed horizontal guides: peak + sustain levels
    move.b  env_slot, d0
    lsl.w   #6, d0
    move.w  d0, d2
    addq.w  #2, d2                          ; curve left = base+2
    move.w  d0, d3
    addi.w  #ENV_SUBW-3, d3                 ; curve right = base+61
    lea     env_pts, a2
    move.w  #ENV_BOT, d4                     ; peak level y = ENV_BOT - aPeak
    sub.w   6(a2), d4
    moveq   #1, d7
    bsr     env_hl
    move.w  #ENV_BOT, d4                     ; sustain level y = ENV_BOT - aSus
    sub.w   10(a2), d4
    moveq   #1, d7
    bsr     env_hl
    rts
.vdash:
    moveq   #ENV_TOP, d2
    moveq   #ENV_BOT, d3
    moveq   #1, d7
    bra     env_vl

draw_hex1:                                ; d3 = value (low nibble), d4 = cursor offset
    move.b  d3, d0
    andi.w  #$000F, d0
    lea     hexd, a1
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_hex2:
    move.b  d3, d0
    lsr.b   #4, d0
    bsr.s   .n
    move.b  d3, d0
.n:
    andi.w  #$000F, d0
    lea     hexd, a1
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_cmd:
    move.b  d3, d0
    bne.s   .v
    moveq   #'.', d0                       ; 0 = no command
    bra.s   .draw
.v:
    addi.b  #$40, d0                       ; 1-26 -> 'A'-'Z' (H = HOP)
.draw:
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_note:
    cmpi.b  #$FF, d3
    bne.s   .real
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
    rts
.real:
    moveq   #0, d0
    move.b  d3, d0
    divu.w  #12, d0
    move.l  d0, d1
    swap    d1
    andi.w  #$000F, d1
    add.w   d1, d1
    lea     note_names, a1
    move.b  (a1,d1.w), d2
    andi.w  #$00FF, d2
    add.w   d4, d2
    move.w  d2, VDP_DATA
    move.b  (1,a1,d1.w), d2
    andi.w  #$00FF, d2
    add.w   d4, d2
    move.w  d2, VDP_DATA
    andi.w  #$00FF, d0
    addi.w  #'0', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

; ============================================================
; multi-voice engine
; ============================================================
; set up all 10 channels from ch_config (4 bytes each: type, p1, p2, p3)
engine_init:
    lea     ch_state, a6
    lea     ch_config, a1
    moveq   #0, d2                        ; channel index = song track
.ci:
    move.b  (a1)+, d0                     ; type
    move.b  d0, c_type(a6)
    move.b  (a1)+, d1                     ; p1
    move.b  (a1)+, d3                     ; p2
    move.b  (a1)+, d4                     ; p3
    cmpi.b  #1, d0
    bne.s   .ci_psg
    move.b  d1, c_ympart(a6)              ; FM: part / chreg / key
    move.b  d3, c_ymchreg(a6)
    move.b  d4, c_ymkey(a6)
    bra.s   .ci_go
.ci_psg:
    move.b  d1, c_psgt(a6)                ; PSG square/noise: tone / vol base
    move.b  d3, c_psgv(a6)
.ci_go:
    move.b  d2, c_track(a6)
    bsr     init_ch
    lea     CHSIZE(a6), a6
    addq.b  #1, d2
    cmpi.b  #NCH, d2
    bne.s   .ci
    move.b  #GROOVE, g_gctr
    move.b  #0, g_seq
    rts

init_ch:                                  ; a6 = channel (c_type/config already set)
    move.b  #$FF, c_note(a6)
    move.w  #0, c_period(a6)
    move.b  #0, c_vol(a6)
    move.b  #0, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #15, c_row(a6)
    move.b  #$FF, c_cstep(a6)            ; pre-start: first advance loads chain step 0
    move.b  #0, c_transp(a6)
    move.b  #0, c_trig(a6)
    move.b  #0, c_keyon(a6)
    move.b  #0, c_kshadow(a6)
    move.b  #$FF, c_hold(a6)             ; gate inactive (no auto key-off until a note sets it)
    move.l  #phrases, c_phrase(a6)
    move.b  #0, c_songpos(a6)            ; song row 0; chain = song[0][track]
    lea     song, a2
    moveq   #0, d0
    move.b  c_track(a6), d0
    move.b  (a2,d0.w), c_chain(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #$FF, c_shadowa(a6)
    rts

; drop any A/V transient overrides and revert F1's patch to the stored instrument
clear_live_patch:
    move.b  #$FF, live_algo
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    move.b  #1, repatch
    rts

toggle_play:
    move.b  playing, d0
    eori.b  #1, d0
    move.b  d0, playing
    bsr     clear_live_patch              ; play/stop = clean slate for A/V overrides
    move.b  playing, d0                   ; (ym_setup clobbered d0)
    tst.b   d0
    beq.s   .tp
    move.b  #0, play_mode                 ; Start = full song from the top
    move.b  #0, play_from
    bsr     engine_play_reset
.tp:
    rts

play_context:                             ; C+B: toggle audition of the current context
    tst.b   playing                        ; already playing -> stop
    beq.s   .pc_start
    move.b  #0, playing
    bra     clear_live_patch              ; drop A/V overrides on stop
.pc_start:
    move.b  cur_screen, d0
    cmpi.b  #SCR_SONG, d0
    bne.s   .pc_ch
    move.b  #0, play_mode                 ; SONG: full song from the cursor row
    move.b  cur_row, play_from
    bra.s   .pc_go
.pc_ch:
    cmpi.b  #SCR_CHAIN, d0
    bne.s   .pc_ph
    move.b  #1, play_mode                 ; CHAIN: solo this track's chain
    bra.s   .pc_go
.pc_ph:
    cmpi.b  #SCR_PHRASE, d0
    bne.s   .pc_done                      ; INSTRUMENT: nothing to audition
    move.b  #2, play_mode                 ; PHRASE: solo this track's phrase
.pc_go:
    move.b  #1, playing
    bsr     clear_live_patch              ; fresh A/V override state each audition
    bsr     engine_play_reset
.pc_done:
    rts

; reset every channel for playback per play_mode (kshadow=$FF forces a key-off,
; silencing any hanging FM note when switching context mid-play)
engine_play_reset:
    move.b  #GROOVE, g_gctr
    moveq   #NCH-1, d7
    lea     ch_state, a6
.r:
    move.b  #$FF, c_note(a6)
    move.b  #15, c_row(a6)
    move.b  #$FF, c_cstep(a6)
    move.b  #0, c_transp(a6)
    move.b  #0, c_estate(a6)
    move.b  #0, c_vol(a6)
    move.b  #0, c_trig(a6)
    move.b  #0, c_keyon(a6)
    move.b  #$FF, c_kshadow(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #$FF, c_shadowa(a6)
    move.l  #phrases, c_phrase(a6)
    tst.b   play_mode
    bne.s   .solo
    move.b  play_from, c_songpos(a6)      ; full song: chain = song[play_from][track]
    lea     song, a2
    moveq   #0, d0
    move.b  play_from, d0
    mulu.w  #NCH, d0
    moveq   #0, d1
    move.b  c_track(a6), d1
    add.w   d1, d0
    move.b  (a2,d0.w), c_chain(a6)
    bra.s   .next
.solo:
    move.b  c_track(a6), d0               ; solo: only cur_chan is active
    cmp.b   cur_chan, d0
    bne.s   .mute
    cmpi.b  #1, play_mode
    bne.s   .phsolo
    move.b  cur_chain, c_chain(a6)         ; chain-solo
    bra.s   .next
.phsolo:                                  ; phrase-solo: load cur_phrase
    move.b  #0, c_chain(a6)               ; placeholder (non-$FF = active)
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0
    lea     phrases, a2
    adda.w  d0, a2
    move.l  a2, c_phrase(a6)
    bra.s   .next
.mute:
    move.b  #$FF, c_chain(a6)              ; inactive (silenced)
.next:
    lea     CHSIZE(a6), a6
    dbra    d7, .r
    rts

engine_tick:
    tst.b   playing
    bne.s   .play
    ; stopped: silence all channels (compose emits the change once)
    lea     scb_data, a3
    moveq   #0, d6
    lea     ym_data, a5
    moveq   #0, d5
    moveq   #NCH-1, d7
    lea     ch_state, a6
.sil:
    move.b  #0, c_vol(a6)
    move.b  #0, c_estate(a6)
    move.b  #0, c_keyon(a6)              ; FM: request key-off
    bsr     compose_ch
    lea     CHSIZE(a6), a6
    dbra    d7, .sil
    move.b  d6, scb_count
    move.b  d5, ym_count
    move.b  d6, d0
    or.b    d5, d0
    or.b    repatch, d0                   ; a pending patch re-push also needs a push
    beq.s   .sret
    bsr     push_scb
.sret:
    rts
.play:
    ; global groove
    addq.b  #1, g_gctr
    move.b  g_gctr, d0
    cmp.b   #GROOVE, d0
    blo.s   .noadv
    move.b  #0, g_gctr
    move.b  #1, eng_adv                   ; playheads moved -> redraw the grid
    moveq   #NCH-1, d7
    lea     ch_state, a6
.adv:
    bsr     advance_ch
    lea     CHSIZE(a6), a6
    dbra    d7, .adv
.noadv:
    ; per-channel envelope + compose (PSG -> a3/d6, FM -> a5/d5)
    lea     scb_data, a3
    moveq   #0, d6
    lea     ym_data, a5
    moveq   #0, d5
    moveq   #NCH-1, d7
    lea     ch_state, a6
.ch:
    bsr     env_ch
    bsr     hold_tick
    bsr     compose_ch
    lea     CHSIZE(a6), a6
    dbra    d7, .ch
    move.b  d6, scb_count
    move.b  d5, ym_count
    move.b  d6, d0
    or.b    d5, d0
    or.b    repatch, d0                   ; a pending patch re-push also needs a push
    beq.s   .nopush
    bsr     push_scb
.nopush:
    rts

; gate countdown: $FF = held; else decrement, and request key-off when it hits 0
hold_tick:                                ; a6 = channel
    move.b  c_hold(a6), d0
    cmpi.b  #$FF, d0
    beq.s   .hret
    subq.b  #1, d0
    move.b  d0, c_hold(a6)
    bne.s   .hret
    move.b  #0, c_keyon(a6)               ; gate expired -> key-off
    move.b  #$FF, c_hold(a6)
.hret:
    rts

advance_ch:                               ; a6 = channel
    cmpi.b  #$FF, c_chain(a6)             ; inactive (muted/empty) -> stay silent
    beq     .ret
    move.b  c_row(a6), d0
    addq.b  #1, d0
    cmpi.b  #16, d0
    blo.s   .gotrow
    cmpi.b  #2, play_mode                 ; phrase-solo: loop the phrase
    bne.s   .nextchain
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0
    lea     phrases, a1
    adda.w  d0, a1
    move.l  a1, c_phrase(a6)
    moveq   #0, d0
    bra.s   .gotrow
.nextchain:
    bsr     advance_chain                 ; phrase ended -> next chain step
    cmpi.b  #$FF, c_chain(a6)             ; became inactive?
    beq     .ret
    moveq   #0, d0
.gotrow:
    move.b  d0, c_row(a6)
    movea.l c_phrase(a6), a1
    move.w  d0, d1                         ; d1 = row*4 (command/param offset)
    lsl.w   #2, d1
    cmpi.b  #1, c_type(a6)                 ; per-note FM reset: a note-on this row reverts the
    bne.s   .noreset                       ;   Q/X overrides to the instrument's stored patch
    cmpi.b  #$FF, (a1,d1.w)               ;   (note byte at row offset 0; $FF = rest = no reset)
    beq.s   .noreset                       ; the Q/X dispatch just below re-applies for this row
    move.b  live_algo, d2                  ; ...but only when an override is actually live:
    and.b   live_vol, d2                   ;   all three $FF = nothing changed = no patch re-push
    and.b   live_fb, d2
    cmpi.b  #$FF, d2
    beq.s   .noreset
    move.b  #$FF, live_algo
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    move.b  #1, repatch
.noreset:
    move.b  (2,a1,d1.w), d2               ; phrase command (letter A-Z = 1..26)
    cmpi.b  #8, d2                         ; H = HOP -> jump to PR row
    beq.s   .cmd_hop
    cmpi.b  #17, d2                        ; Q xy = one-shot ALGO(x)+FB(y) override
    beq     .cmd_q
    cmpi.b  #24, d2                        ; X xx = volume (carrier TL)
    beq     .cmd_x
    bra     .cmddone
.cmd_hop:
    moveq   #0, d2
    move.b  (3,a1,d1.w), d2               ; param = destination row (low nibble)
    andi.b  #$0F, d2
    subq.b  #1, d2                         ; next advance does +1, landing on param
    move.b  d2, c_row(a6)
    bra     .cmddone
.cmd_q:
    cmpi.b  #1, c_type(a6)                 ; FM channels only
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; PR = (ALGO<<4)|FB
    move.b  d2, d3
    lsr.b   #4, d3                         ; x nibble = ALGO 0-7
    andi.b  #7, d3
    move.b  d3, live_algo                  ; TRANSIENT overrides (reset on play/stop)
    andi.b  #7, d2                         ; y nibble = FB 0-7
    move.b  d2, live_fb
    move.b  #1, repatch                    ; engine appends the patch to this tick's SCB push
    bra     .cmddone
.cmd_x:
    cmpi.b  #1, c_type(a6)
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; PR = new volume 0-15
    andi.b  #$0F, d2
    move.b  d2, live_vol                   ; TRANSIENT override
    move.b  #1, repatch
.cmddone:
    lsl.w   #2, d0
    moveq   #0, d2
    move.b  (a1,d0.w), d2                 ; note (0-95) or $FF
    cmpi.w  #$FF, d2
    beq     .ret
    move.b  c_transp(a6), d3              ; + transpose (signed)
    ext.w   d3
    add.w   d3, d2
    bmi     .ret
    cmpi.w  #96, d2
    bhs     .ret
    move.b  d2, c_note(a6)
    move.b  c_type(a6), d3
    beq.s   .square
    cmpi.b  #2, d3
    beq.s   .noise
    move.b  #1, c_trig(a6)               ; FM: (re)trigger the note
    move.b  #1, c_keyon(a6)
    lea     instrum, a4                  ; HLD: gate time from the current instrument
    moveq   #0, d2
    move.b  cur_instr, d2
    mulu.w  #INSTR_SIZE, d2
    move.b  (i_hld,a4,d2.w), d2
    cmpi.b  #15, d2                      ; $F = hold until the next note
    bne.s   .hldcnt
    move.b  #$FF, c_hold(a6)
    rts
.hldcnt:
    add.b   d2, d2                       ; HLD*2 (+1 so HLD=0 still gates, and != $FF)
    addq.b  #1, d2
    move.b  d2, c_hold(a6)
    rts
.noise:                                   ; noise: note -> mode (low 3 bits), AHD vol
    andi.w  #$0007, d2
    move.w  d2, c_period(a6)
    move.b  #1, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #0, c_vol(a6)
    rts
.square:
    add.w   d2, d2
    lea     notetable, a2
    move.w  (a2,d2.w), c_period(a6)
    move.b  #1, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #0, c_vol(a6)
.ret:
    rts

; next chain step; on chain end ($FF), advance the song row instead of looping
advance_chain:                            ; a6 = channel
    moveq   #0, d1
    move.b  c_cstep(a6), d1
    addq.b  #1, d1
    andi.b  #$0F, d1
    lea     chains, a2
    moveq   #0, d0
    move.b  c_chain(a6), d0
    lsl.w   #5, d0                        ; * CHAIN_SIZE
    adda.w  d0, a2
    moveq   #0, d0
    move.b  d1, d0
    add.w   d0, d0                        ; step * 2
    move.b  (a2,d0.w), d2                 ; phrase# at this step
    cmpi.b  #$FF, d2
    bne.s   .step
    cmpi.b  #1, play_mode                 ; chain-solo: loop chain (step 0)
    bne.s   advance_song                  ; else: chain done -> next song row
    moveq   #0, d1
.step:
    move.b  d1, c_cstep(a6)
    bra.s   load_step                     ; d1 = step

; advance the channel's song row; load its chain at step 0 (loop song on $FF)
advance_song:                             ; a6 = channel
    moveq   #0, d3
    move.b  c_songpos(a6), d3
    addq.b  #1, d3
    moveq   #0, d0
    move.b  c_track(a6), d0
    move.w  d3, d4                        ; song[d3][track] = d3*NCH + track
    mulu.w  #NCH, d4
    add.w   d0, d4
    lea     song, a2
    move.b  (a2,d4.w), d2                 ; chain# at new row
    cmpi.b  #$FF, d2
    bne.s   .ok
    moveq   #0, d3                        ; song end -> loop to row 0
    move.b  (a2,d0.w), d2                 ; song[0][track]
.ok:
    move.b  d3, c_songpos(a6)
    move.b  d2, c_chain(a6)
    move.b  #0, c_cstep(a6)
    moveq   #0, d1                        ; chain step 0
    ; fall into load_step

load_step:                                ; a6 = channel; d1 = chain step
    lea     chains, a2
    moveq   #0, d0
    move.b  c_chain(a6), d0
    lsl.w   #5, d0
    adda.w  d0, a2
    moveq   #0, d0
    move.b  d1, d0
    add.w   d0, d0                        ; step * 2
    move.b  (a2,d0.w), d2                 ; phrase#
    move.b  (1,a2,d0.w), c_transp(a6)     ; transpose
    moveq   #0, d3
    move.b  d2, d3
    lsl.w   #6, d3                        ; * PHRASE_SIZE
    lea     phrases, a1
    adda.w  d3, a1
    move.l  a1, c_phrase(a6)
    rts

env_ch:                                   ; a6 = channel
    cmpi.b  #1, c_type(a6)                 ; only FM uses the YM2612 hardware envelope
    beq.s   .fmskip
    move.b  c_estate(a6), d0
    bne.s   .on
    rts
.fmskip:
    rts
.on:
    cmpi.b  #1, d0
    bne.s   .nh
    move.b  #I_VOL, c_vol(a6)
    move.b  #2, c_estate(a6)
    move.b  #0, c_ectr(a6)
    rts
.nh:
    cmpi.b  #2, d0
    bne.s   .dc
    addq.b  #1, c_ectr(a6)
    move.b  c_ectr(a6), d1
    cmpi.b  #I_HLD, d1
    blo.s   .h
    move.b  #3, c_estate(a6)
    move.b  #0, c_ectr(a6)
.h:
    rts
.dc:
    addq.b  #1, c_ectr(a6)
    move.b  c_ectr(a6), d1
    cmpi.b  #I_DCY, d1
    blo.s   .d
    move.b  #0, c_ectr(a6)
    move.b  c_vol(a6), d1
    beq.s   .off
    subq.b  #1, d1
    move.b  d1, c_vol(a6)
    bne.s   .d
.off:
    move.b  #0, c_estate(a6)
.d:
    rts

compose_ch:                               ; a6=ch; a3/d6=PSG buf; a5/d5=YM buf
    move.b  c_type(a6), d0
    beq.s   .square
    cmpi.b  #2, d0
    beq     compose_noise
    bra     compose_fm
.square:
    moveq   #15, d1
    sub.b   c_vol(a6), d1                 ; attenuation
    move.w  c_period(a6), d2
    cmp.w   c_shadowp(a6), d2
    beq.s   .sp
    move.w  d2, c_shadowp(a6)
    move.b  c_psgt(a6), d3
    move.b  d2, d0
    andi.b  #$0F, d0
    or.b    d0, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
    move.w  d2, d0
    lsr.w   #4, d0
    andi.w  #$003F, d0
    move.b  d0, (a3)+
    addq.b  #1, d6
.sp:
    cmp.b   c_shadowa(a6), d1
    beq.s   .sa
    move.b  d1, c_shadowa(a6)
    move.b  c_psgv(a6), d3
    or.b    d1, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
.sa:
    rts

; PSG noise compose: control byte ($E0|mode from c_period) + vol ($F0|atten)
compose_noise:                            ; a6=ch; a3/d6=PSG buf
    moveq   #15, d1
    sub.b   c_vol(a6), d1
    move.w  c_period(a6), d2
    cmp.w   c_shadowp(a6), d2
    beq.s   .nv
    move.w  d2, c_shadowp(a6)
    move.b  c_psgt(a6), d3                ; $E0
    move.b  d2, d0
    andi.b  #$07, d0                       ; noise mode 0-7
    or.b    d0, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
.nv:
    cmp.b   c_shadowa(a6), d1
    beq.s   .nd
    move.b  d1, c_shadowa(a6)
    move.b  c_psgv(a6), d3                ; $F0
    or.b    d1, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
.nd:
    rts

; FM compose: emit YM writes (part,reg,value triples) into a5, count in d5
compose_fm:                               ; a6=ch; a5=YM ptr; d5=triple count
    move.b  c_trig(a6), d0
    beq.s   .nochg
    move.b  #0, c_trig(a6)
    move.b  #0, (a5)+                       ; key-off: part0, $28, ymkey
    move.b  #$28, (a5)+
    move.b  c_ymkey(a6), (a5)+
    addq.w  #1, d5
    moveq   #0, d0
    move.b  c_note(a6), d0
    bsr     fm_freq                        ; d1=$A4 val, d2=$A0 val
    move.b  c_ympart(a6), (a5)+            ; freq hi: part, $A4+chreg, d1
    move.b  #$A4, d3
    add.b   c_ymchreg(a6), d3
    move.b  d3, (a5)+
    move.b  d1, (a5)+
    addq.w  #1, d5
    move.b  c_ympart(a6), (a5)+            ; freq lo: part, $A0+chreg, d2
    move.b  #$A0, d3
    add.b   c_ymchreg(a6), d3
    move.b  d3, (a5)+
    move.b  d2, (a5)+
    addq.w  #1, d5
    move.b  #0, (a5)+                       ; key-on: part0, $28, $F0|ymkey
    move.b  #$28, (a5)+
    move.b  c_ymkey(a6), d3
    ori.b   #$F0, d3
    move.b  d3, (a5)+
    addq.w  #1, d5
    move.b  #1, c_kshadow(a6)
    rts
.nochg:
    move.b  c_keyon(a6), d0               ; key state changed (e.g. stop -> off)?
    cmp.b   c_kshadow(a6), d0
    beq.s   .done
    move.b  d0, c_kshadow(a6)
    move.b  #0, (a5)+
    move.b  #$28, (a5)+
    move.b  c_ymkey(a6), d3
    tst.b   d0
    beq.s   .off
    ori.b   #$F0, d3                        ; key-on
.off:
    move.b  d3, (a5)+
    addq.w  #1, d5
.done:
    rts

; d0 = note (0-95) -> d1 = $A4 value (block<<3 | fnum hi), d2 = $A0 value (fnum lo)
fm_freq:
    andi.l  #$0000FFFF, d0
    divu.w  #12, d0                         ; low = block(octave), high = semitone
    move.w  d0, d4                          ; block
    clr.w   d0
    swap    d0                             ; semitone
    add.w   d0, d0                         ; * 2
    lea     fm_fnum, a1
    move.w  (a1,d0.w), d2                  ; fnum
    move.w  d2, d1
    lsr.w   #8, d1                         ; fnum >> 8
    andi.w  #$0007, d4
    lsl.w   #3, d4                         ; block << 3
    or.w    d4, d1                         ; $A4 value
    andi.w  #$00FF, d2                     ; $A0 value
    rts

push_scb:
    move.w  #$0100, Z80_BUSREQ
.w:
    btst    #0, Z80_BUSREQ
    bne.s   .w
    move.b  scb_count, d0                ; --- PSG section ---
    move.b  d0, Z80_RAM+$1F01
    beq.s   .nopsg
    ext.w   d0
    subq.w  #1, d0
    lea     scb_data, a4
    lea     Z80_RAM+$1F02, a3
.pcp:
    move.b  (a4)+, (a3)+
    dbra    d0, .pcp
.nopsg:
    moveq   #0, d7                        ; --- YM section (triples) ---
    move.b  ym_count, d7                 ; running triple count (composed note SCB)
    lea     Z80_RAM+$1F21, a2            ; mailbox YM write pointer
    tst.b   d7
    beq.s   .ymap
    move.w  d7, d0
    mulu.w  #3, d0
    subq.w  #1, d0
    lea     ym_data, a4
.ycp:
    move.b  (a4)+, (a2)+
    dbra    d0, .ycp
.ymap:
    tst.b   repatch                       ; Q/X command or FM edit -> append the patch to THIS push
    beq.s   .noym
    move.b  #0, repatch
    bsr     ym_build_patch                ; appends into (a2)+, d7 += patch count (no race)
.noym:
    move.b  d7, Z80_RAM+$1F20            ; final ym_count = notes + (maybe) patch
    addq.b  #1, g_seq
    move.b  g_seq, Z80_RAM+$1F00
    move.w  #$0000, Z80_BUSREQ
    rts

; push a YM2612 write list (part,reg,value triples) once: patch + key-on
; build YM ch0's patch from instrument 0's record and push it to the Z80.
; per op (n=0..3, reg offset n*4): $30=(DT<<4)|MUL $40=TL $50=AR $60=D1R
; $70=D2R $80=(SL<<4)|RR; then $B0=(FB<<3)|ALGO, $B4=$C0 (L+R)
ym_setup:                                 ; editor/boot path: own BUSREQ, build into the mailbox, push
    move.w  #$0100, Z80_BUSREQ
.w:
    btst    #0, Z80_BUSREQ
    bne.s   .w
    move.b  #0, Z80_RAM+$1F01            ; psg_count = 0
    lea     Z80_RAM+$1F21, a2            ; build straight into the YM mailbox
    moveq   #0, d7
    bsr     ym_build_patch
    move.b  d7, Z80_RAM+$1F20            ; ym_count
    addq.b  #1, g_seq
    move.b  g_seq, Z80_RAM+$1F00
    move.w  #$0000, Z80_BUSREQ
    rts

; build F1's patch (part,reg,value triples) into (a2)+, advancing d7 by the count.
; caller sets a2 (dest) + d7 (running count). NO BUSREQ / push of its own, so it is
; safe to call both standalone (ym_setup) and mid-SCB (push_scb's repatch append).
ym_build_patch:
    lea     instrum, a3                   ; the live instrument -> F1's voice
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    move.b  live_algo, d0                ; effective ALGO = transient override or stored value
    cmpi.b  #$FF, d0
    bne.s   .haveal
    move.b  (i_algo,a3), d0
.haveal:
    move.b  d0, eff_algo
    move.b  live_vol, d0                 ; effective VOL = transient override or stored value
    cmpi.b  #$FF, d0
    bne.s   .havevl
    move.b  (i_vol,a3), d0
.havevl:
    move.b  d0, eff_vol
    move.b  live_fb, d0                  ; effective FB = transient override or stored value
    cmpi.b  #$FF, d0
    bne.s   .havefb
    move.b  (i_fb,a3), d0
.havefb:
    move.b  d0, eff_fb
    moveq   #0, d4                        ; $22: global LFO (enable bit 3 | rate 0-2)
    moveq   #0, d0
    move.b  g_lfo, d0
    beq.s   .nolfo
    subq.b  #1, d0
    ori.b   #$08, d0
.nolfo:
    move.b  #$22, d2
    bsr     .emit
    moveq   #0, d6                        ; operator slot 0..3 (rows are in register order)
.op:                                      ; params: MUL DT TL RS AR AM D1 D2 RR SL
    move.w  d6, d5
    mulu.w  #FM_NPARM, d5
    addi.w  #i_op, d5                     ; param base = i_op + slot*10
    move.w  d6, d4
    lsl.w   #2, d4                        ; reg offset = slot*4 (S1,S3,S2,S4 = rows OP1,OP3,OP2,OP4)
    move.b  (1,a3,d5.w), d1               ; $30: (DT<<4)|MUL
    lsl.b   #4, d1
    move.b  (0,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$30, d2
    bsr     .emit
    move.b  (2,a3,d5.w), d0               ; $40: TL (+ VOL attenuation if this op is a carrier)
    moveq   #0, d1
    move.b  eff_algo, d1
    andi.w  #7, d1
    lea     carrier_mask, a4
    btst    d6, (a4,d1.w)                 ; slot d6 a carrier in this algorithm?
    beq.s   .novol
    moveq   #15, d1                       ; atten = (15 - VOL) * 8
    sub.b   eff_vol, d1
    lsl.b   #3, d1
    add.b   d1, d0
    cmpi.b  #127, d0                      ; clamp (unsigned)
    bls.s   .novol
    moveq   #127, d0
.novol:
    move.b  #$40, d2
    bsr     .emit
    move.b  (3,a3,d5.w), d1               ; $50: (RS<<6)|AR
    lsl.b   #6, d1
    move.b  (4,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$50, d2
    bsr     .emit
    move.b  (5,a3,d5.w), d1               ; $60: (AM<<7)|D1R
    lsl.b   #7, d1
    move.b  (6,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$60, d2
    bsr     .emit
    move.b  (7,a3,d5.w), d0               ; $70: D2R
    move.b  #$70, d2
    bsr     .emit
    move.b  (9,a3,d5.w), d1               ; $80: (SL<<4)|RR
    lsl.b   #4, d1
    move.b  (8,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$80, d2
    bsr     .emit
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .op
    moveq   #0, d4                        ; $B0: (FB<<3)|ALGO
    move.b  eff_fb, d1
    lsl.b   #3, d1
    move.b  eff_algo, d0
    or.b    d1, d0
    move.b  #$B0, d2
    bsr     .emit
    move.b  (i_pan,a3), d0                ; $B4: (pan<<6)|(AMS<<4)|FMS
    lsl.b   #6, d0
    move.b  (i_ams,a3), d1
    andi.b  #3, d1
    lsl.b   #4, d1
    or.b    d1, d0
    move.b  (i_fms,a3), d1
    andi.b  #7, d1
    or.b    d1, d0
    move.b  #$B4, d2
    bsr     .emit
    rts
.emit:                                    ; emit triple: part0, (d2+d4), d0
    move.b  #0, (a2)+
    move.b  d2, d1
    add.b   d4, d1
    move.b  d1, (a2)+
    move.b  d0, (a2)+
    addq.w  #1, d7
    rts

; ============================================================
z80_load:
    move.w  #$0100, Z80_BUSREQ
    move.w  #$0100, Z80_RESET
.wb:
    btst    #0, Z80_BUSREQ
    bne.s   .wb
    lea     z80_blob, a1
    lea     Z80_RAM, a2
    move.w  #z80_blob_end-z80_blob-1, d0
.zc:
    move.b  (a1)+, (a2)+
    dbra    d0, .zc
    move.w  #$0000, Z80_RESET
    move.w  #$0000, Z80_BUSREQ
    moveq   #40, d0
.zd:
    dbra    d0, .zd
    move.w  #$0100, Z80_RESET
    rts

print_at:
    moveq   #0, d0
    move.w  d3, d0
    lsl.w   #6, d0
    add.w   d4, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
.pl:
    move.b  (a1)+, d1
    beq.s   .pd
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    bra.s   .pl
.pd:
    rts

Exception:
    bra.s   Exception

; ============================================================
; data
; ============================================================
str_title:  dc.b "GENMDDJ",0
ver_str:    dc.b "V0.01",0
str_hdr_ph: dc.b "   NOT IN C PR",0
str_hdr_ch: dc.b "   PH TR      ",0
str_hdr_sg: dc.b "   F1 F2 F3 F4 F5 F6 T1 T2 T3 NO",0
str_hdr_in: dc.b "              ",0
str_hdr_fm: dc.b "OP  MU DT TL RS AR AM D1 D2 RR SL",0
str_scr_ph: dc.b "PHRASE",0
str_scr_ch: dc.b "CHAIN ",0
str_scr_sg: dc.b "SONG  ",0
str_scr_in: dc.b "INSTR ",0
str_scr_fm: dc.b "FM    ",0
op_names:   dc.b "OP1OP3OP2OP4"            ; rows in YM2612 register order (S1,S3,S2,S4)
fm_scol:    dc.b 5, 8, 11, 14, 17, 20, 23, 26, 29, 32   ; 10 op-param columns
fm_pmax:    dc.b 15, 7, 127, 3, 31, 1, 31, 31, 15, 15   ; MUL DT TL RS AR AM D1 D2 RR SL
    even
str_inst:   dc.b "INST",0
str_type:   dc.b "TYPE",0
str_voice:  dc.b "VOICE:",0
str_algo:   dc.b "ALGO",0
str_fb:     dc.b "FB",0
str_pan:    dc.b "PAN",0
str_ams:    dc.b "AMS",0
str_fms:    dc.b "FMS",0
str_hld:    dc.b "HLD",0
str_vol:    dc.b "VOL",0
str_lfo:    dc.b "LFO",0
str_global: dc.b "(GLOBAL)",0
    even
voice_lbl:  dc.l str_algo, str_fb, str_pan, str_ams, str_fms, str_hld, str_vol  ; 7
voice_off:  dc.b i_algo, i_fb, i_pan, i_ams, i_fms, i_hld, i_vol
voice_max:  dc.b 7, 7, 3, 3, 7, 15, 15
    even
NVOICE     equ 7                            ; voice params before the (global) LFO row
type_names: dc.b "FMSQNOKI"                 ; 2 chars per type (FM SQ NO KIt)
map_letters: dc.b "SCPI"                    ; map order: SONG CHAIN PHRASE INSTR
str_play:   dc.b "PLAY",0
str_stop:   dc.b "STOP",0
hexd:       dc.b "0123456789ABCDEF"
note_names: dc.b "C-C#D-D#E-F-F#G-G#A-A#B-"
field_scol: dc.b 4, 8, 11, 13
field_boff: dc.b 0, 1, 2, 3
chain_scol: dc.b 4, 7
song_scol:  dc.b 4, 7, 10, 13, 16, 19, 22, 25, 28, 31
track_names: dc.b "F1F2F3F4F5F6T1T2T3NO"      ; 2 chars per channel
ch_config:                                      ; type, p1, p2, p3 per channel
    dc.b 1, 0, 0, 0          ; F1 = FM YM ch0
    dc.b 1, 0, 1, 1          ; F2 = FM YM ch1
    dc.b 1, 0, 2, 2          ; F3 = FM YM ch2
    dc.b 1, 1, 0, 4          ; F4 = FM YM ch3
    dc.b 1, 1, 1, 5          ; F5 = FM YM ch4
    dc.b 1, 1, 2, 6          ; F6 = FM YM ch5
    dc.b 0, $80, $90, 0      ; T1 = square PSG ch0
    dc.b 0, $A0, $B0, 0      ; T2 = square PSG ch1
    dc.b 0, $C0, $D0, 0      ; T3 = square PSG ch2
    dc.b 2, $E0, $F0, 0      ; NO = noise PSG ch3
scr_order:  dc.b SCR_SONG, SCR_CHAIN, SCR_PHRASE, SCR_INSTR   ; map pos -> screen id
scr_pos:    dc.b 2, 1, 0, 3, $FF            ; screen id -> map pos ($FF = off the row, FM)
    even
scr_ph_tab: dc.l str_hdr_ph, str_scr_ph    ; {header, name} per screen
scr_ch_tab: dc.l str_hdr_ch, str_scr_ch
scr_sg_tab: dc.l str_hdr_sg, str_scr_sg
scr_in_tab: dc.l str_hdr_in, str_scr_in
scr_fm_tab: dc.l str_hdr_in, str_scr_fm     ; row-3 header blank (render_fm draws its own)

tri_tile:                                   ; right-pointing playhead (tile $1F)
    dc.l $00000000
    dc.l $01000000
    dc.l $01100000
    dc.l $01110000
    dc.l $01110000
    dc.l $01100000
    dc.l $01000000
    dc.l $00000000

; 4 single-note phrases (note at row 0, rests after): C-4 E-4 G-4 C-5
demo_phrases:
    dc.b 48,0,0,0            ; phrase 0  C-4
    rept 15
    dc.b $FF,0,0,0
    endr
    dc.b 52,0,0,0            ; phrase 1  E-4
    rept 15
    dc.b $FF,0,0,0
    endr
    dc.b 55,0,0,0            ; phrase 2  G-4
    rept 15
    dc.b $FF,0,0,0
    endr
    dc.b 60,0,0,0            ; phrase 3  C-5
    rept 15
    dc.b $FF,0,0,0
    endr
demo_end:
    even

; chains (2 steps each so the chain playhead has somewhere to move):
; each step = (phrase#, transpose); $FF phrase# = end-of-chain
demo_chains:
    dc.b 0,0, 3,0          ; chain 0: C-4 then C-5
    dcb.b CHAIN_SIZE-4, $FF
    dc.b 1,0, 2,0          ; chain 1: E-4 then G-4
    dcb.b CHAIN_SIZE-4, $FF
    dc.b 2,0, 1,0          ; chain 2: G-4 then E-4
    dcb.b CHAIN_SIZE-4, $FF
    dc.b 3,0, 0,0          ; chain 3: C-5 then C-4
    dcb.b CHAIN_SIZE-4, $FF
demo_chains_end:
    even

; song: chain# per track (F1 F2 F3 F4 F5 F6 T1 T2 T3 NO); $FF = empty/inactive
; demo plays F1 (FM) + T1 + T2 (square); the rest are silent
demo_song:
    dc.b 0,   $FF,$FF,$FF,$FF,$FF,  1,   2,   $FF, $FF   ; row 0
    dc.b 3,   $FF,$FF,$FF,$FF,$FF,  2,   1,   $FF, $FF   ; row 1
    dcb.b (NSONGROWS-2)*NCH, $FF
demo_song_end:
    even

; M6-A FM test: a minimal patch on YM channel 1 + key-on.
; triples: part(0=ch1-3), reg, value. algorithm 7 (all ops are carriers),
; op1 loud, ops 2-4 muted -> a single sine-ish FM voice.
; default FM voice (instrument 0): algo 7 (all carriers), op1 loud, op2-4 muted
default_fm:                        ; YM2612 grand-piano test patch (Sega manual)
    dc.b 0, 2, 6, 3, 0,0,15,15     ; type, algo=2, fb=6, pan(L+R), ams, fms, HLD=hold, VOL=full
    dc.b 1, 7, 35, 1,31,0,5,2,1,1  ; slot0 S1: MUL DT TL RS AR AM D1 D2 RR SL ($30=71..$80=11)
    dc.b 13,0, 45, 2,25,0,5,2,1,1  ; slot1 S3 ($34=0D..$84=11)
    dc.b 3, 3, 38, 1,31,0,5,2,1,1  ; slot2 S2 ($38=33..$88=11)
    dc.b 1, 0, 0,  2,20,0,7,2,6,10 ; slot3 S4 carrier ($3C=01..$8C=A6)
    even

; carrier slots per algorithm (bit d6 set = record slot d6 is a carrier, in S1,S3,S2,S4
; register order). VOL attenuates only carriers so it scales output without retiming/timbre.
carrier_mask:
    dc.b $08,$08,$08,$08,$0C,$0E,$0E,$0F
    even

; YM2612 F-numbers for one octave (C..B); block = note/12 selects the octave
fm_fnum:
    dc.w 644, 682, 723, 766, 811, 859, 910, 965, 1022, 1083, 1147, 1215
    even

vdp_regs:
    dc.b $04, $74, $30, $3C, $07, $6C, $00, $00
    dc.b $00, $00, $00, $00, $81, $34, $00, $02
    dc.b $01, $00, $00, $FF, $FF, $00, $00, $80
vdp_regs_end:
    even

notetable:
    incbin "build/notes.bin"
    even
z80_blob:
    incbin "build/driver.z80.bin"
z80_blob_end:
    even
    include "build/gitver.i"             ; git_hash_str (build stamp)
    even
splash_tiles:
    incbin "build/splash_tiles.bin"
splash_map:
    incbin "build/splash_map.bin"
    even
algo_tiles:
    incbin "build/algo_tiles.bin"
algo_maps:
    incbin "build/algo_maps.bin"
    even
font_data:
    incbin "build/font.bin"
font_end:
    even

    dcb.b $20000-*, $FF
ROM_END:
